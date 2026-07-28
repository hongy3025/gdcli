## GdApiRuntimeTransportFileEditor 单元测试
##
## 在 SceneTree 进程里跑通编辑器侧文件 transport 的核心行为：
## 1) 扫描 hello.json 发现 probe；
## 2) broker.request() 通过 send 写 inbox，outbox reply 交给 broker；
## 3) 未知或格式错误的 outbox 文件删除且不触发 callback。
##
## 测试不依赖真实 Game 进程。真实 broker 持有 id、pending 和回调；
## editor transport 只负责文件收发。

@tool
extends SceneTree

const Transport := preload("res://addons/gdapi/runtime/runtime_transport_file_editor.gd")
const Broker := preload("res://addons/gdapi/runtime/runtime_broker.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeTransportFileEditor tests...")

	test_scan_picks_up_new_hello_file()
	test_editor_transport_exposes_no_business_request_or_timeout_path()
	test_broker_request_writes_inbox_and_outbox_reply_reaches_broker()
	test_unknown_outbox_reply_is_deleted_without_callback()
	test_malformed_outbox_reply_preserves_live_broker_pending_request()
	test_invalid_outbox_reply_preserves_live_broker_pending_request()

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

func assert_false(value: bool, context: String = "") -> void:
	assert_eq(value, false, context)

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
	t.setup(Broker.new())
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids(), ["probe1234"], "hello detected")
	_cleanup(root)

func test_editor_transport_exposes_no_business_request_or_timeout_path() -> void:
	var t := Transport.new(_make_root())
	assert_false(t.has_method("request"), "editor transport has no business request entry point")
	assert_false(t.has_method("pending_count"), "editor transport has no pending counter")
	assert_false(t.has_method("_expire_timeouts"), "editor transport has no local timeout path")

func test_broker_request_writes_inbox_and_outbox_reply_reaches_broker() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe5678")
	var broker := Broker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var received: Array = []
	var id: int = broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply)
	)
	var inbox_file := root.path_join("probe5678/inbox/%d.json" % id)
	assert_true(FileAccess.file_exists(inbox_file), "inbox file written")
	# 模拟 probe 写 outbox
	var outbox_file := root.path_join("probe5678/outbox/%d.json" % id)
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(JSON.stringify({
		"version": 1, "id": id, "kind": "reply",
		"ok": true, "result": {"echo": id}
	}))
	of.close()
	t.tick(Time.get_ticks_msec())
	assert_eq(received.size(), 1, "reply callback fired")
	if not received.is_empty():
		assert_eq(received[0]["result"]["echo"], id, "reply payload correct")
	assert_eq(broker.status().pending, 0, "broker pending cleared")
	_cleanup(root)

func test_unknown_outbox_reply_is_deleted_without_callback() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe9999")
	var broker := Broker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var outbox_file := root.path_join("probe9999/outbox/999.json")
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(JSON.stringify({"version":1,"id":999,"kind":"reply","ok":true,"result":{}}))
	of.close()
	t.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(outbox_file), "unknown outbox file deleted")
	assert_eq(broker.status().pending, 0, "unknown reply does not create pending")
	_cleanup(root)

func test_invalid_outbox_reply_preserves_live_broker_pending_request() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe_bad")
	var broker := Broker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var callbacks: Array = []
	var id: int = broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		callbacks.append(reply)
	)
	var outbox_file := root.path_join("probe_bad/outbox/%d.json" % id)
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(JSON.stringify({"version": 2, "id": id, "kind": "reply", "ok": true}))
	of.close()
	t.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(outbox_file), "invalid outbox file deleted")
	assert_eq(callbacks.size(), 0, "invalid reply does not invoke callback")
	assert_eq(broker.status().pending, 1, "invalid reply preserves broker pending request")
	_cleanup(root)

func test_malformed_outbox_reply_preserves_live_broker_pending_request() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	_seed_probe(root, "probe_malformed")
	var broker := Broker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var callbacks: Array = []
	var id: int = broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		callbacks.append(reply)
	)
	var outbox_file := root.path_join("probe_malformed/outbox/%d.json" % id)
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string("not-json")
	of.close()
	t.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(outbox_file), "malformed outbox file deleted")
	assert_eq(callbacks.size(), 0, "malformed reply does not invoke callback")
	assert_eq(broker.status().pending, 1, "malformed reply preserves broker pending request")
	_cleanup(root)
