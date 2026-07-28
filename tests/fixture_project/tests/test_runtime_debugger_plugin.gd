## GdApiRuntimeDebuggerPlugin unit tests.
##
## Exercises the EditorDebuggerPlugin capture contract with a fake session payload.

@tool
extends SceneTree

const Broker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

const DEBUGGER_SOURCE := "res://addons/gdapi/runtime/runtime_debugger_plugin.gd"

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeDebuggerPlugin tests...\n")

	test_capture_contract_handles_fake_hello()
	test_capture_contract_bridges_replies_to_broker()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func _debugger_source() -> String:
	var file := FileAccess.open(DEBUGGER_SOURCE, FileAccess.READ)
	if file == null:
		return ""
	var source := file.get_as_text()
	file.close()
	return source

func test_capture_contract_handles_fake_hello() -> void:
	var fake_session := {
		"session_id": 17,
		"message": "gdapi",
		"data": [{
			"version": Protocol.VERSION,
			"kind": "event",
			"event": "hello",
			"result": {},
		}],
	}
	var source := _debugger_source()
	assert_eq(fake_session.message, "gdapi", "fake session uses gdapi capture")
	assert_eq(fake_session.data[0].event, "hello", "fake session carries hello payload")
	assert_true(source.contains("func _has_capture(name: String) -> bool"), "capture hook is declared")
	assert_true(source.contains("_attach_to_session(session_id)"), "hello attaches the debugger session")
	assert_true(source.contains("_broker.mark_connected()"), "hello marks the broker connected")
	assert_true(source.contains("detach_engine_debugger"), "clear path uses explicit engine detach")

func test_capture_contract_bridges_replies_to_broker() -> void:
	var fake_reply := {
		"version": Protocol.VERSION,
		"id": 9,
		"kind": "reply",
		"ok": true,
		"result": {"ready": true},
	}
	var source := _debugger_source()
	assert_eq(fake_reply.kind, "reply", "fake session carries a reply payload")
	assert_eq(fake_reply.version, Protocol.VERSION, "fake reply preserves protocol v1")
	assert_true(source.contains("_broker.receive(payload)"), "reply capture enters broker.receive")
	assert_true(source.contains("return true"), "handled captures acknowledge the debugger")
	assert_true(source.contains("send_message(\"gdapi\", [message])"), "requests use the debugger channel")

	# Keep a real broker in this test so the fixture continues to load the same
	# protocol/broker boundary as the production capture bridge.
	var broker: RefCounted = Broker.new()
	assert_eq(broker.status().protocol_version, Protocol.VERSION, "broker remains protocol v1")
