## Broker/file transport combination tests.
##
## These tests intentionally exercise the current pre-migration ownership seams.
## They are expected to remain RED until the broker owns all pending replies and
## the probe supports suspended handlers and transport generations.

@tool
extends SceneTree

const Broker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const EditorTransport := preload("res://addons/gdapi/runtime/runtime_transport_file_editor.gd")
const ProbeTransport := preload("res://addons/gdapi/runtime/runtime_transport_file_probe.gd")
const RuntimeProbe := preload("res://addons/gdapi/runtime/runtime_probe.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

class FakeRuntimeMain extends Node:
	var reset_calls := 0

	func reset_fixture() -> Dictionary:
		reset_calls += 1
		return {"changed": true, "undoable": false}

var passed := 0
var failed := 0

func _init() -> void:
	print("Running runtime broker/file transport integration tests...")
	call_deferred("_run")

func _run() -> void:
	_cleanup(_make_root())
	await test_broker_file_sync_roundtrip()
	await test_broker_file_async_roundtrip()
	await test_reply_completes_once()
	await test_unknown_and_duplicate_reply_are_ignored()
	await test_timeout_then_late_reply_is_ignored()
	await test_generation_and_priority_reject_stale_hello()
	test_runtime_probe_requires_stripped_protocol_channel()
	await test_fixture_reset_uses_one_fixed_helper_and_rejects_payload()

	_cleanup(_make_root())
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func _exit_tree() -> void:
	_cleanup(_make_root())

func assert_eq(actual: Variant, expected: Variant, context: String = "") -> void:
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
		_cleanup(root.path_join(sub))
	DirAccess.remove_absolute(root)

func _write_json(path: String, message: Dictionary) -> void:
	var parent := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(parent)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(message))
	file.close()

func _write_inbox(root: String, probe_id: String, id: int, message: Dictionary) -> void:
	_write_json(root.path_join(probe_id).path_join("inbox").path_join("%d.json" % id), message)

func _write_outbox(root: String, probe_id: String, id: int, message: Dictionary) -> void:
	_write_json(root.path_join(probe_id).path_join("outbox").path_join("%d.json" % id), message)

func _receive_outbox(root: String, probe_id: String, id: int, broker: RefCounted) -> bool:
	var path := root.path_join(probe_id).path_join("outbox").path_join("%d.json" % id)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var reply: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	DirAccess.remove_absolute(path)
	if typeof(reply) != TYPE_DICTIONARY:
		return false
	if typeof(reply.get("version")) == TYPE_FLOAT:
		reply["version"] = int(reply.version)
	if typeof(reply.get("id")) == TYPE_FLOAT:
		reply["id"] = int(reply.id)
	broker.receive(reply)
	return true

func _callback_counter() -> Dictionary:
	return {"count": 0, "last": {}}

func _make_pair(root: String, handler: Callable) -> Dictionary:
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	var broker: RefCounted = Broker.new()
	var editor: RefCounted = EditorTransport.new(root)
	editor.setup(broker)
	editor.start()
	var probe: RefCounted = ProbeTransport.new(0, root)
	probe.set_request_handler(handler)
	probe.start()
	editor.tick(Time.get_ticks_msec())
	return {"broker": broker, "editor": editor, "probe": probe}

func _sync_handler(message: Dictionary) -> Dictionary:
	return {"ok": true, "result": {"echo": int(message.get("id", -1))}}

func _async_handler(message: Dictionary) -> Dictionary:
	await process_frame
	await process_frame
	return {"ok": true, "result": {"echo": int(message.get("id", -1))}}

func _reply(id: int, result: Dictionary = {}) -> Dictionary:
	return Protocol.reply(id, true, result)

func _stop_pair(root: String, pair: Dictionary) -> void:
	pair.probe.stop()
	pair.editor.stop_all("test cleanup")
	pair.clear()
	_cleanup(root)

func test_broker_file_sync_roundtrip() -> void:
	var root := _make_root()
	var pair := _make_pair(root, Callable(self, "_sync_handler"))
	var callback := _callback_counter()
	var id: int = pair.broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		callback.count += 1
		callback.last = reply
	)
	pair.probe.tick(Time.get_ticks_msec())
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "sync callback count")
	assert_eq(callback.last.get("result", {}).get("echo", -1), id, "sync callback result")
	assert_eq(pair.broker.status().pending, 0, "sync broker pending")
	assert_true(not FileAccess.file_exists(root.path_join(pair.probe.probe_id()).path_join("outbox/%d.json" % id)),
		"sync outbox removed")
	_stop_pair(root, pair)

func test_broker_file_async_roundtrip() -> void:
	var root := _make_root()
	var pair := _make_pair(root, Callable(self, "_async_handler"))
	var callback := _callback_counter()
	var id: int = pair.broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		callback.count += 1
		callback.last = reply
	)
	pair.probe.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(root.path_join(pair.probe.probe_id()).path_join("outbox/%d.json" % id)),
		"async outbox waits before first resume")
	await process_frame
	pair.probe.tick(Time.get_ticks_msec())
	assert_true(not FileAccess.file_exists(root.path_join(pair.probe.probe_id()).path_join("outbox/%d.json" % id)),
		"async outbox waits before second resume")
	await process_frame
	pair.probe.tick(Time.get_ticks_msec())
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "async callback count")
	assert_eq(callback.last.get("result", {}).get("echo", -1), id, "async callback result")
	assert_eq(pair.broker.status().pending, 0, "async broker pending")
	_stop_pair(root, pair)

func test_reply_completes_once() -> void:
	var root := _make_root()
	var pair := _make_pair(root, Callable(self, "_sync_handler"))
	var callback := _callback_counter()
	var id: int = pair.broker.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		callback.count += 1
		callback.last = reply
	)
	pair.probe.tick(Time.get_ticks_msec())
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "reply completes once")
	assert_eq(pair.broker.status().pending, 0, "reply leaves broker pending zero")
	_write_outbox(root, pair.probe.probe_id(), id, _reply(id, {"echo": id}))
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "duplicate reply ignored after completion")
	_stop_pair(root, pair)

func test_unknown_and_duplicate_reply_are_ignored() -> void:
	var root := _make_root()
	var pair := _make_pair(root, Callable(self, "_sync_handler"))
	var callback := _callback_counter()
	var id: int = pair.broker.request("runtime/status", {}, 5000, func(_reply: Dictionary) -> void:
		callback.count += 1
	)
	_write_outbox(root, pair.probe.probe_id(), 9999, _reply(9999))
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 0, "unknown reply ignored")
	pair.probe.tick(Time.get_ticks_msec())
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "known reply callback count")
	_write_outbox(root, pair.probe.probe_id(), id, _reply(id))
	pair.editor.tick(Time.get_ticks_msec())
	assert_eq(callback.count, 1, "duplicate reply ignored")
	_stop_pair(root, pair)

func test_timeout_then_late_reply_is_ignored() -> void:
	var root := _make_root()
	var pair := _make_pair(root, Callable(self, "_sync_handler"))
	var callback := _callback_counter()
	var id: int = pair.broker.request("runtime/status", {}, 1, func(reply: Dictionary) -> void:
		callback.count += 1
		callback.last = reply
	)
	pair.broker.tick(Time.get_ticks_msec() + 100)
	assert_eq(callback.count, 1, "timeout callback count")
	assert_eq(callback.last.get("code", ""), "timeout", "timeout callback code")
	_write_outbox(root, pair.probe.probe_id(), id, _reply(id))
	pair.editor.tick(Time.get_ticks_msec())
	pair.broker.receive(_reply(id))
	assert_eq(callback.count, 1, "late reply ignored after timeout")
	assert_eq(pair.broker.status().pending, 0, "late reply leaves broker pending zero")
	_stop_pair(root, pair)

func test_generation_and_priority_reject_stale_hello() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	var broker: RefCounted = Broker.new()
	var engine_sent: Array = []
	broker.attach(7, func(message: Dictionary) -> bool:
		engine_sent.append(message)
		return true
	)
	broker.mark_connected()
	broker._set_active_transport("engine_debugger")
	assert_eq(broker.status().session_id, 7, "real broker session established")
	assert_eq(broker.status().transport, "engine_debugger", "engine debugger priority before file hello")
	if not broker.has_method("begin_generation"):
		assert_true(false, "generation contract requires broker.begin_generation()")
		broker = null
		_cleanup(root)
		return
	var stale_generation: String = String(broker.call("begin_generation"))
	var current_generation: String = String(broker.call("begin_generation"))
	# begin_generation intentionally detaches the previous transport; bind the
	# current debugger session to the new generation before testing priority.
	broker.attach(7, func(message: Dictionary) -> bool:
		engine_sent.append(message)
		return true
	, current_generation)
	broker.mark_connected()
	var session_id: int = int(broker.status().session_id)
	var current_probe_id := "current123"
	_write_json(root.path_join(current_probe_id).path_join("hello.json"), Protocol.event(0, "hello", {
		"protocol_version": Protocol.VERSION,
		"transport": "file",
		"generation": current_generation,
		"pid": 1,
		"started_at": 1.0,
		"session_id": session_id,
	}))
	var editor: RefCounted = EditorTransport.new(root)
	editor.setup(broker)
	editor.start()
	editor.tick(Time.get_ticks_msec())
	assert_eq(editor.active_probe_ids(), [current_probe_id], "current generation accepted")
	var stale_probe_id := "stale123"
	_write_json(root.path_join(stale_probe_id).path_join("hello.json"), Protocol.event(0, "hello", {
		"protocol_version": Protocol.VERSION,
		"transport": "file",
		"generation": stale_generation,
		"pid": 1,
		"started_at": 1.0,
		"session_id": session_id,
	}))
	editor.tick(Time.get_ticks_msec())
	assert_eq(editor.active_probe_ids(), [current_probe_id], "stale generation rejected")
	assert_eq(broker.status().transport, "engine_debugger", "engine debugger keeps priority")
	editor.stop_all("test cleanup")
	editor = null
	broker = null
	_cleanup(root)

func test_runtime_probe_requires_stripped_protocol_channel() -> void:
	var root := _make_root()
	_cleanup(root)
	DirAccess.make_dir_recursive_absolute(root)
	var broker: RefCounted = Broker.new()
	var generation: String = String(broker.call("begin_generation"))
	_write_json(root.path_join("generation.json"), {"generation": generation})
	var transport: RefCounted = ProbeTransport.new(0, root)
	transport.start()
	var probe: Node = RuntimeProbe.new()
	probe._file_transport = transport
	probe.record_log("info", "must remain")

	var request := Protocol.request(91, "runtime/log/clear", {}, generation)
	assert_eq(transport.generation(), generation, "probe adopts broker generation")
	assert_eq(probe._on_runtime_capture("gdapi", [request]), false, "bare EngineDebugger channel is ignored")
	assert_eq(probe._on_runtime_capture("gdapi:protocol", [request]), false, "full EngineDebugger channel is not passed to runtime callback")
	assert_eq(probe._on_runtime_capture("protocol", [request]), true, "runtime receives stripped protocol channel")
	assert_eq(probe.ring_buffer().size(), 0, "accepted request remains isolated from file transport")

	probe.free()
	probe = null
	transport.stop()
	broker = null
	_cleanup(root)

func test_fixture_reset_uses_one_fixed_helper_and_rejects_payload() -> void:
	var fixture := FakeRuntimeMain.new()
	fixture.name = "RuntimeMain"
	root.add_child(fixture)
	var probe: Node = root.get_node_or_null("GdApiRuntimeProbe")
	assert_true(probe != null, "fixture project provides the runtime probe autoload")
	if probe == null:
		fixture.free()
		return
	probe.record_log("info", "must be cleared")

	assert_true(probe.has_method("reset_shared_fixture"),
		"probe exposes one fixed fixture reset helper")
	if probe.has_method("reset_shared_fixture"):
		var direct: Dictionary = probe.call("reset_shared_fixture")
		assert_eq(direct.get("ok", false), true, "fixed helper succeeds")
		assert_eq(fixture.reset_calls, 1, "fixed helper resets known RuntimeMain")
		assert_eq(direct.get("cleared_logs", -1), 1,
			"fixed helper reports the ring entries it cleared")
		assert_eq(probe.ring_buffer().size(), 0, "fixed helper clears probe ring")

	var rejected: Dictionary = await probe._dispatch_async(
		"runtime/fixture/reset", {"op": "runtime/node/remove"})
	assert_eq(rejected.get("code", ""), "invalid_param",
		"internal reset rejects all payload fields")

	fixture.free()
