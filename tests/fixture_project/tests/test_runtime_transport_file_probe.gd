@tool
extends SceneTree

const Transport := preload("res://addons/gdapi/runtime/runtime_transport_file_probe.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeTransportFileProbe tests...")
	call_deferred("_run")

func _run() -> void:

	test_probe_id_is_unique_hex()
	test_root_dir_under_dot_godot()
	test_start_writes_hello_file()
	test_hello_contains_generation_metadata()
	test_inbox_request_triggers_callback()
	await test_suspended_request_claims_duplicate_id_and_finishes_once()
	await test_suspended_request_times_out_once()
	test_completed_request_id_never_restarts_after_outbox_consumed()
	test_failed_outbox_write_retries_without_losing_reply()
	test_non_dictionary_inbox_is_discarded()
	test_malformed_handler_reply_becomes_structured_error()
	test_oversized_handler_reply_becomes_structured_error()
	test_stop_recursively_removes_probe_directory()

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
	for name in dir.get_files():
		dir.remove(name)
	for sub in dir.get_directories():
		var sub_dir := DirAccess.open(root.path_join(sub))
		if sub_dir != null:
			for n in sub_dir.get_files():
				sub_dir.remove(n)
			sub_dir.remove(sub)
	DirAccess.remove_absolute(root)

func _write_request(path: String, id: int) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(Protocol.request(id, "runtime/status", {})))
	file.close()

func _read_reply(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var raw: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var reply: Dictionary = raw
	if typeof(reply.get("version")) == TYPE_FLOAT:
		reply["version"] = int(reply.version)
	if typeof(reply.get("id")) == TYPE_FLOAT:
		reply["id"] = int(reply.id)
	return reply

func test_probe_id_is_unique_hex() -> void:
	var a := Transport.new()
	var b := Transport.new()
	var ida := a.probe_id()
	var idb := b.probe_id()
	assert_eq(ida.length(), 8, "probe id length 8")
	assert_eq(idb.length(), 8, "probe id length 8")
	assert_true(ida != idb, "probe ids are unique")

func test_root_dir_under_dot_godot() -> void:
	var t := Transport.new()
	var root := t.root_path()
	assert_true(root.ends_with(".godot/gdapi_runtime") or root.contains("/.godot/gdapi_runtime"),
		"root under .godot/gdapi_runtime, got %s" % root)

func test_start_writes_hello_file() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.start()
	var hello_path := root.path_join(t.probe_id()).path_join("hello.json")
	assert_true(FileAccess.file_exists(hello_path), "hello.json written")
	var f := FileAccess.open(hello_path, FileAccess.READ)
	var content := f.get_as_text()
	f.close()
	assert_true(content.contains("\"event\":\"hello\""), "hello event payload")
	assert_true(content.contains("\"protocol_version\":1"), "protocol_version present")
	t.stop()
	_cleanup(root)

func test_hello_contains_generation_metadata() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.start()
	var path := root.path_join(t.probe_id()).path_join("hello.json")
	var hello_file := FileAccess.open(path, FileAccess.READ)
	var raw: Variant = JSON.parse_string(hello_file.get_as_text())
	hello_file.close()
	var result: Dictionary = raw.get("result", {})
	assert_true(not String(result.get("generation", "")).is_empty(), "hello generation present")
	assert_true(int(result.get("pid", 0)) > 0, "hello pid present")
	assert_true(float(result.get("started_at", 0.0)) > 0.0, "hello started_at present")
	assert_eq(result.get("transport"), "file", "hello transport present")
	t.stop()
	_cleanup(root)

func test_inbox_request_triggers_callback() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	var received: Array = []
	t.set_request_handler(func(msg: Dictionary) -> Dictionary:
		received.append(msg)
		return {"ok": true, "result": {"echo": msg.get("id", -1)}}
	)
	t.start()
	# 模拟编辑器写 inbox 请求
	var probe_dir := root.path_join(t.probe_id())
	DirAccess.make_dir_recursive_absolute(probe_dir.path_join("inbox"))
	var req_path := probe_dir.path_join("inbox").path_join("42.json")
	var rf := FileAccess.open(req_path, FileAccess.WRITE)
	rf.store_string(JSON.stringify({
		"version": 1, "id": 42, "kind": "request",
		"op": "runtime/status", "payload": {}
	}))
	rf.close()
	# 推进 tick
	t.tick(Time.get_ticks_msec())
	# 验证回调被调用 + reply 落盘
	assert_eq(received.size(), 1, "request handler invoked once")
	var out_path := probe_dir.path_join("outbox").path_join("42.json")
	assert_true(FileAccess.file_exists(out_path), "outbox reply written")
	t.stop()
	_cleanup(root)

func test_suspended_request_claims_duplicate_id_and_finishes_once() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	var tracker := {"calls": 0}
	t.set_request_handler(func(msg: Dictionary) -> Dictionary:
		tracker.calls += 1
		await process_frame
		await process_frame
		return {"ok": true, "result": {"echo": msg.get("id", -1)}}
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	_write_request(probe_dir.path_join("inbox/42.json"), 42)
	_write_request(probe_dir.path_join("inbox/duplicate-42.json"), 42)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "duplicate inbox id starts one suspended handler")
	assert_true(not FileAccess.file_exists(probe_dir.path_join("inbox/42.json")), "claimed inbox removed")
	assert_true(not FileAccess.file_exists(probe_dir.path_join("inbox/duplicate-42.json")), "duplicate inbox removed")
	assert_true(t._inflight.has(42), "suspended request remains inflight")
	var out_path := probe_dir.path_join("outbox/42.json")
	assert_true(not FileAccess.file_exists(out_path), "no outbox before first resume")
	await process_frame
	t.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(out_path), "no outbox before second resume")
	await process_frame
	t.tick(Time.get_ticks_msec())
	assert_true(FileAccess.file_exists(out_path), "one outbox reply after handler resume")
	var reply := _read_reply(out_path)
	assert_true(Protocol.validate_message(reply).ok, "suspended reply is protocol valid")
	assert_eq(reply.get("result", {}).get("echo", -1), 42, "suspended reply result")
	assert_true(not t._inflight.has(42), "finished request clears inflight")
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "finished duplicate request is never restarted")
	t.stop()
	_cleanup(root)

func test_suspended_request_times_out_once() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.handler_timeout_ms = 1
	var tracker := {"calls": 0}
	t.set_request_handler(func(_msg: Dictionary) -> Dictionary:
		tracker.calls += 1
		await create_timer(60.0).timeout
		return {"ok": true}
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	_write_request(probe_dir.path_join("inbox/45.json"), 45)
	var now := Time.get_ticks_msec()
	t.tick(now)
	assert_eq(tracker.calls, 1, "timeout handler starts once")
	assert_true(t._inflight.has(45), "timeout handler enters inflight")
	t.tick(now + 2)
	var out_path := probe_dir.path_join("outbox/45.json")
	var reply := _read_reply(out_path)
	assert_true(Protocol.validate_message(reply).ok, "timeout reply is protocol valid")
	assert_eq(reply.get("code", ""), "timeout", "timeout reply has stable code")
	assert_true(not t._inflight.has(45), "timeout clears inflight")
	var first_timeout_reply := JSON.stringify(reply)
	t.tick(now + 3)
	assert_eq(JSON.stringify(_read_reply(out_path)), first_timeout_reply, "timeout reply is written once")
	_write_request(probe_dir.path_join("inbox/duplicate-45.json"), 45)
	t.tick(now + 4)
	assert_eq(tracker.calls, 1, "timed out id never restarts")
	t.stop()
	_cleanup(root)

func test_completed_request_id_never_restarts_after_outbox_consumed() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	var tracker := {"calls": 0}
	t.set_request_handler(func(_msg: Dictionary) -> Dictionary:
		tracker.calls += 1
		return {"ok": true}
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	_write_request(probe_dir.path_join("inbox/46.json"), 46)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "sync request starts once")
	assert_true(not t._inflight.has(46), "sync reply clears inflight")
	var out_path := probe_dir.path_join("outbox/46.json")
	assert_true(FileAccess.file_exists(out_path), "sync reply reaches outbox")
	_write_request(probe_dir.path_join("inbox/replayed-before-consume-46.json"), 46)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "sync-completed id never restarts before outbox consumption")
	DirAccess.remove_absolute(out_path)
	_write_request(probe_dir.path_join("inbox/replayed-46.json"), 46)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "completed id never restarts after outbox consumption")
	assert_true(not FileAccess.file_exists(probe_dir.path_join("inbox/replayed-46.json")), "completed duplicate is removed")
	t.stop()
	_cleanup(root)

func test_failed_outbox_write_retries_without_losing_reply() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	var tracker := {"calls": 0}
	t.set_request_handler(func(_msg: Dictionary) -> Dictionary:
		tracker.calls += 1
		return {"ok": true, "result": {"saved": true}}
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	var blocked_tmp := probe_dir.path_join("outbox/47.json.tmp")
	DirAccess.make_dir_absolute(blocked_tmp)
	_write_request(probe_dir.path_join("inbox/47.json"), 47)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "write failure dispatches handler once")
	assert_true(t._inflight.has(47), "write failure retains inflight reply")
	assert_true(not FileAccess.file_exists(probe_dir.path_join("outbox/47.json")), "write failure emits no partial outbox")
	DirAccess.remove_absolute(blocked_tmp)
	t.tick(Time.get_ticks_msec())
	var reply := _read_reply(probe_dir.path_join("outbox/47.json"))
	assert_true(Protocol.validate_message(reply).ok, "retried outbox reply is protocol valid")
	assert_eq(reply.get("result", {}).get("saved", false), true, "retried outbox preserves reply")
	assert_true(not t._inflight.has(47), "successful retry clears inflight")
	_write_request(probe_dir.path_join("inbox/replayed-47.json"), 47)
	t.tick(Time.get_ticks_msec())
	assert_eq(tracker.calls, 1, "retried completion never redispatches id")
	t.stop()
	_cleanup(root)

func test_malformed_handler_reply_becomes_structured_error() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.set_request_handler(func(_msg: Dictionary) -> Variant:
		return "not a reply dictionary"
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	_write_request(probe_dir.path_join("inbox/43.json"), 43)
	t.tick(Time.get_ticks_msec())
	var reply := _read_reply(probe_dir.path_join("outbox/43.json"))
	assert_true(Protocol.validate_message(reply).ok, "malformed handler reply becomes protocol reply")
	assert_eq(reply.get("ok", true), false, "malformed handler reply fails")
	assert_eq(reply.get("code", ""), "invalid_param", "malformed handler reply has stable code")
	assert_true(not t._inflight.has(43), "malformed reply clears inflight")
	t.stop()
	_cleanup(root)

func test_non_dictionary_inbox_is_discarded() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.start()
	var inbox_path := root.path_join(t.probe_id()).path_join("inbox/invalid.json")
	var file := FileAccess.open(inbox_path, FileAccess.WRITE)
	file.store_string("[]")
	file.close()
	t.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(inbox_path), "non-dictionary inbox is discarded")
	t.stop()
	_cleanup(root)

func test_oversized_handler_reply_becomes_structured_error() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.set_request_handler(func(_msg: Dictionary) -> Dictionary:
		return {"ok": true, "result": {"body": "x".repeat(Protocol.MAX_MESSAGE_BYTES)}}
	)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	_write_request(probe_dir.path_join("inbox/44.json"), 44)
	t.tick(Time.get_ticks_msec())
	var reply := _read_reply(probe_dir.path_join("outbox/44.json"))
	assert_true(Protocol.validate_message(reply).ok, "oversized handler reply becomes bounded protocol reply")
	assert_eq(reply.get("ok", true), false, "oversized handler reply fails")
	assert_eq(reply.get("code", ""), "invalid_param", "oversized handler reply has stable code")
	assert_true(not t._inflight.has(44), "oversized reply clears inflight")
	t.stop()
	_cleanup(root)

func test_stop_recursively_removes_probe_directory() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.start()
	var probe_dir := root.path_join(t.probe_id())
	var nested := FileAccess.open(probe_dir.path_join("inbox/stale.json"), FileAccess.WRITE)
	nested.store_string("stale")
	nested.close()
	var nested_outbox := FileAccess.open(probe_dir.path_join("outbox/stale.json"), FileAccess.WRITE)
	nested_outbox.store_string("stale")
	nested_outbox.close()
	t.stop()
	assert_true(not DirAccess.dir_exists_absolute(probe_dir), "probe stop removes nested files")
	_cleanup(root)
