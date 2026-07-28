## GdApiRuntimeTransportFileEditor 单元测试
##
## 在 SceneTree 进程里跑通编辑器侧文件 transport 的核心行为：
## 1) 扫描 hello.json 发现 probe；
## 2) request() 写 inbox、等 outbox 回包、把 reply 投到 callback；
## 3) 未知 id 的 outbox 文件被忽略（不污染 pending）；
## 4) request 超时清理 pending 字典并触发 timeout callback。
##
## 测试不依赖真实 Game 进程。StubBroker 提供 attach_file_transport / allocate_id
## 等最小契约,让 EditorTransport._attach_probe 调用不会报方法缺失。

@tool
extends SceneTree

const Transport := preload("res://addons/gdapi/runtime/runtime_transport_file_editor.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeTransportFileEditor tests...")

	test_scan_picks_up_new_hello_file()
	test_request_writes_inbox_and_reads_outbox()
	test_outbox_for_unknown_id_is_ignored()
	test_request_timeout_clears_pending()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	if failed > 0:
		quit(1)
	else:
		quit(0)

func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func _make_root() -> String:
	return ProjectSettings.globalize_path("res://.godot/gdapi_runtime_test")

func _cleanup(root: String) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for sub in dir.get_directories():
		var sub_dir := DirAccess.open(root.path_join(sub))
		if sub_dir != null:
			for n in sub_dir.get_files():
				sub_dir.remove(n)
			sub_dir.remove(sub)
	DirAccess.remove_absolute(root)

func _seed_probe(root: String, probe_id: String) -> void:
	var dir := root.path_join(probe_id)
	DirAccess.make_dir_recursive_absolute(dir.path_join("inbox"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("outbox"))
	var hello_path := dir.path_join("hello.json")
	var f := FileAccess.open(hello_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"version": 1, "id": 0, "kind": "event",
		"event": "hello", "result": {"protocol_version": 1, "transport": "file"}
	}))
	f.close()

func test_scan_picks_up_new_hello_file() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe1234")
	var t := Transport.new(root)
	t.setup(StubBroker.new())
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids(), ["probe1234"], "hello detected")
	_cleanup(root)

func test_request_writes_inbox_and_reads_outbox() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe5678")
	var broker := StubBroker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var received: Array = []
	t.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply)
	)
	# inbox 文件应该被写入
	var inbox_file := root.path_join("probe5678/inbox/1.json")
	assert_true(FileAccess.file_exists(inbox_file), "inbox file written")
	# 模拟 probe 写 outbox
	var outbox_file := root.path_join("probe5678/outbox/1.json")
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(JSON.stringify({
		"version": 1, "id": 1, "kind": "reply",
		"ok": true, "result": {"echo": 1}
	}))
	of.close()
	t.tick(Time.get_ticks_msec())
	assert_eq(received.size(), 1, "reply callback fired")
	assert_eq(received[0]["result"]["echo"], 1, "reply payload correct")
	_cleanup(root)

func test_outbox_for_unknown_id_is_ignored() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe9999")
	var t := Transport.new(root)
	t.setup(StubBroker.new())
	t.start()
	t.tick(Time.get_ticks_msec())
	var outbox_file := root.path_join("probe9999/outbox/999.json")
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(JSON.stringify({"version":1,"id":999,"kind":"reply","ok":true,"result":{}}))
	of.close()
	t.tick(Time.get_ticks_msec())
	# pending 仍然 0,unknown id 不会触发回调
	assert_eq(t.pending_count(), 0, "no pending")
	_cleanup(root)

func test_request_timeout_clears_pending() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe_to")
	var t := Transport.new(root)
	t.setup(StubBroker.new())
	t.start()
	t.tick(Time.get_ticks_msec())
	var received: Array = []
	t.request("runtime/status", {}, 30, func(reply: Dictionary) -> void:
		received.append(reply)
	)
	# 推进时间超过 timeout
	var deadline := Time.get_ticks_msec() + 80
	while Time.get_ticks_msec() < deadline:
		await process_frame
		t.tick(Time.get_ticks_msec())
	assert_eq(received.size(), 1, "timeout callback fired")
	assert_eq(received[0]["code"], "timeout", "timeout code")
	assert_eq(t.pending_count(), 0, "pending cleared")
	_cleanup(root)

## 最小 stub,提供 EditorTransport._attach_probe 期望的方法。
## 不模拟真实 broker 的状态机——只让 attach_file_transport 调用成功即可。
class StubBroker:
	extends RefCounted
	var next_id: int = 0
	func allocate_id() -> int:
		next_id += 1
		return next_id
	func attach_file_transport(_probe_id: String, _send: Callable) -> void:
		pass
	func detach_file_transport(_reason: String = "") -> void:
		pass
