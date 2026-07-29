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
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

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
	test_stale_hello_is_removed_and_current_hello_attaches()
	test_integral_float_hello_pid_attaches()
	test_hello_requires_generation_metadata()
	test_disappeared_hello_detaches_probe()
	test_stale_outbox_reply_cannot_complete_current_request()
	test_stop_all_recursively_removes_probe_files()

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
	f.store_string(
		JSON.stringify(
			{
				"version": 1,
				"id": 0,
				"kind": "event",
				"event": "hello",
				"result":
				{
					"protocol_version": 1,
					"generation": "seed-generation",
					"pid": 1,
					"started_at": 1.0,
					"transport": "file"
				}
			}
		)
	)
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
	var id: int = broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: received.append(reply)
	)
	var inbox_file := root.path_join("probe5678/inbox/%d.json" % id)
	assert_true(FileAccess.file_exists(inbox_file), "inbox file written")
	# 模拟 probe 写 outbox
	var outbox_file := root.path_join("probe5678/outbox/%d.json" % id)
	var of := FileAccess.open(outbox_file, FileAccess.WRITE)
	of.store_string(
		JSON.stringify(
			{
				"version": 1,
				"id": id,
				"kind": "reply",
				"ok": true,
				"result": {"echo": id},
				"generation": "seed-generation"
			}
		)
	)
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
	of.store_string(
		JSON.stringify({"version": 1, "id": 999, "kind": "reply", "ok": true, "result": {}})
	)
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
	var id: int = broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: callbacks.append(reply)
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
	var id: int = broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: callbacks.append(reply)
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


func _write_json(path: String, value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(value))
	f.close()


func _hello(generation: String) -> Dictionary:
	return {
		"version": 1,
		"id": 0,
		"kind": "event",
		"event": "hello",
		"result":
		{
			"protocol_version": 1,
			"generation": generation,
			"pid": 1,
			"started_at": 1.0,
			"transport": "file"
		},
	}


func test_stale_hello_is_removed_and_current_hello_attaches() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var stale: String = String(broker.begin_generation())
	var current: String = String(broker.begin_generation())
	_write_json(root.path_join("stale/hello.json"), _hello(stale))
	_write_json(root.path_join("current/hello.json"), _hello(current))
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids(), ["current"], "only current hello attaches")
	assert_true(
		not FileAccess.file_exists(root.path_join("stale/hello.json")), "stale hello is removed"
	)
	t.stop_all("test cleanup")
	_cleanup(root)


func test_hello_requires_generation_metadata() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var generation: String = String(broker.begin_generation())
	var hello := (
		Protocol
		. event(
			0,
			"hello",
			{
				"protocol_version": Protocol.VERSION,
				"generation": generation,
			}
		)
	)
	_write_json(root.path_join("incomplete/hello.json"), hello)
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids().size(), 0, "incomplete hello is rejected")
	assert_true(
		not FileAccess.file_exists(root.path_join("incomplete/hello.json")),
		"incomplete hello is removed"
	)
	t.stop_all("test cleanup")
	_cleanup(root)


func test_integral_float_hello_pid_attaches() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var generation: String = String(broker.begin_generation())
	var hello := _hello(generation)
	hello["result"]["pid"] = 1.0
	_write_json(root.path_join("float-pid/hello.json"), hello)
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids(), ["float-pid"], "integral float hello pid attaches")
	t.stop_all("test cleanup")
	_cleanup(root)


func test_disappeared_hello_detaches_probe() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var generation: String = String(broker.begin_generation())
	_write_json(root.path_join("probe/hello.json"), _hello(generation))
	_write_json(root.path_join("probe/inbox/stale.json"), {"stale": true})
	_write_json(root.path_join("probe/outbox/stale.json"), {"stale": true})
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids(), ["probe"], "probe attached before disappearance")
	DirAccess.remove_absolute(root.path_join("probe/hello.json"))
	t.tick(Time.get_ticks_msec())
	assert_eq(t.active_probe_ids().size(), 0, "missing hello detaches probe")
	assert_eq(broker.status().state, "stopped", "missing hello stops broker")
	assert_true(
		not DirAccess.dir_exists_absolute(root.path_join("probe")),
		"missing hello removes probe directory recursively"
	)
	t.stop_all("test cleanup")
	_cleanup(root)


func test_stale_outbox_reply_cannot_complete_current_request() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var stale: String = String(broker.begin_generation())
	var current: String = String(broker.begin_generation())
	_write_json(root.path_join("probe/hello.json"), _hello(current))
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	t.tick(Time.get_ticks_msec())
	var received: Array = []
	var id: int = broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: received.append(reply)
	)
	assert_eq(received.size(), 0, "current request remains pending before reply")
	assert_eq(broker.status().pending, 1, "current request enters pending")
	_write_json(
		root.path_join("probe/outbox/%d.json" % id),
		Protocol.reply(id, true, {"stale": true}, "", "", stale)
	)
	t.tick(Time.get_ticks_msec())
	assert_eq(received.size(), 0, "stale outbox does not complete request")
	assert_eq(broker.status().pending, 1, "stale outbox leaves pending")
	_write_json(
		root.path_join("probe/outbox/%d.json" % id),
		Protocol.reply(id, true, {"generationless": true})
	)
	t.tick(Time.get_ticks_msec())
	assert_eq(received.size(), 0, "generationless outbox does not complete request")
	assert_eq(broker.status().pending, 1, "generationless outbox leaves pending")
	t.stop_all("test cleanup")
	_cleanup(root)


func test_stop_all_recursively_removes_probe_files() -> void:
	var root := _make_root()
	_cleanup(root)
	var broker: RefCounted = Broker.new()
	var t := Transport.new(root)
	t.setup(broker)
	t.start()
	_write_json(root.path_join("probe/hello.json"), _hello(broker.begin_generation()))
	_write_json(root.path_join("probe/inbox/1.json"), {"stale": true})
	_write_json(root.path_join("probe/outbox/2.json"), {"stale": true})
	t.stop_all("test cleanup")
	assert_true(not DirAccess.dir_exists_absolute(root), "stop removes runtime root")
	_cleanup(root)
