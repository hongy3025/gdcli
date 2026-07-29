## Behavioral tests for the runtime debugger bridge and registration lifecycle.
##
## EditorDebuggerPlugin is a virtual editor-only Godot class, so the tests
## instantiate the narrow production bridge used by that plugin instead.

@tool
extends SceneTree

const Broker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const DebuggerBridge := preload("res://addons/gdapi/runtime/runtime_debugger_bridge.gd")
const DebuggerRegistration := preload("res://addons/gdapi/runtime/runtime_debugger_registration.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")


class FakeSession:
	extends RefCounted
	var sent: Array = []

	func send_message(channel: String, payload: Array) -> void:
		sent.append({"channel": channel, "payload": payload})


var passed := 0
var failed := 0


func _init() -> void:
	print("Running GdApiRuntimeDebugger behavioral tests...\n")

	test_registration_calls_add_and_remove_once()
	test_capture_hello_attaches_and_reply_reaches_broker()
	test_stale_session_clear_does_not_detach_active_session()
	test_malformed_hello_is_rejected_before_connecting()
	test_hello_requires_generation_metadata()

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


func assert_false(value: bool, context: String = "") -> void:
	assert_eq(value, false, context)


func _valid_hello() -> Dictionary:
	return (
		Protocol
		. event(
			0,
			"hello",
			{
				"protocol_version": Protocol.VERSION,
				"node": "behavioral-test",
				"generation": "test-generation",
				"pid": 1,
				"started_at": 1.0,
				"transport": "engine_debugger",
			}
		)
	)


func _attach_fake_session(bridge: RefCounted, broker: RefCounted, session_id: int) -> FakeSession:
	var session := FakeSession.new()
	bridge.setup(broker)
	bridge.setup_session(session_id)
	bridge.set_session_override(session_id, session)
	return session


func test_registration_calls_add_and_remove_once() -> void:
	var calls: Array = []
	var fake_plugin := RefCounted.new()
	var registration: RefCounted = DebuggerRegistration.new()
	registration.setup(
		fake_plugin,
		func(_plugin: Object) -> void: calls.append("add"),
		func(_plugin: Object) -> void: calls.append("remove")
	)
	registration.register()
	registration.register()
	assert_eq(calls, ["add"], "registration calls add once")
	assert_true(registration.registered, "registration state is observable")
	registration.unregister()
	registration.unregister()
	assert_eq(calls, ["add", "remove"], "unregistration calls remove once")
	assert_false(registration.registered, "unregistration state is observable")


func test_capture_hello_attaches_and_reply_reaches_broker() -> void:
	var bridge: RefCounted = DebuggerBridge.new()
	var broker: RefCounted = Broker.new()
	var session := _attach_fake_session(bridge, broker, 17)
	assert_false(bridge.capture("gdapi", [_valid_hello()], 17), "bare debugger channel is rejected")
	assert_true(
		bridge.capture("gdapi:protocol", [_valid_hello()], 17), "full debugger channel is handled"
	)
	assert_eq(broker.status().transport, "engine_debugger", "hello activates engine debugger")
	assert_eq(broker.status().session_id, 17, "hello binds session id")

	var received: Array = []
	var request_id: int = broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: received.append(reply)
	)
	assert_eq(session.sent.size(), 1, "request is sent through fake debugger session")
	assert_eq(
		session.sent[0].get("channel", ""), "gdapi:protocol", "session sends full debugger channel"
	)
	assert_true(
		bridge.capture(
			"gdapi:protocol", [Protocol.reply(request_id, true, {"generationless": true})], 17
		),
		"generationless reply is consumed"
	)
	assert_eq(received.size(), 0, "generationless debugger reply is ignored")
	assert_eq(broker.status().pending, 1, "generationless debugger reply leaves pending")
	var generation: String = String(broker.status().get("generation", ""))
	assert_true(
		bridge.capture(
			"gdapi:protocol",
			[Protocol.reply(request_id, true, {"ready": true}, "", "", generation)],
			17
		),
		"reply capture is handled"
	)
	assert_eq(received.size(), 1, "reply reaches broker callback")
	assert_eq(received[0].get("ok"), true, "broker receives successful reply")


func test_stale_session_clear_does_not_detach_active_session() -> void:
	var bridge: RefCounted = DebuggerBridge.new()
	var broker: RefCounted = Broker.new()
	_attach_fake_session(bridge, broker, 23)
	assert_true(bridge.capture("gdapi:protocol", [_valid_hello()], 23), "active hello is handled")
	var received: Array = []
	broker.request(
		"runtime/status", {}, 5000, func(reply: Dictionary) -> void: received.append(reply)
	)
	bridge.setup_session(99)
	bridge.clear(99)
	assert_eq(broker.status().transport, "engine_debugger", "stale clear keeps active transport")
	assert_eq(broker.status().pending, 1, "stale clear keeps pending request")
	assert_eq(received.size(), 0, "stale clear does not fail callback")

	bridge.clear(23)
	assert_eq(broker.status().transport, "none", "active clear detaches engine transport")
	assert_eq(broker.status().pending, 0, "active clear drains pending")
	assert_eq(received.size(), 1, "active clear fails pending once")
	bridge.clear(23)
	assert_eq(received.size(), 1, "duplicate clear does not repeat callback")


func test_malformed_hello_is_rejected_before_connecting() -> void:
	var bridge: RefCounted = DebuggerBridge.new()
	var broker: RefCounted = Broker.new()
	_attach_fake_session(bridge, broker, 31)
	var malformed := _valid_hello()
	malformed["version"] = 2
	assert_false(
		bridge.capture("gdapi:protocol", [malformed], 31), "wrong-version hello is rejected"
	)
	assert_eq(broker.status().transport, "none", "wrong-version hello does not activate transport")
	assert_eq(broker.status().state, "stopped", "wrong-version hello leaves broker stopped")

	var malformed_shape := _valid_hello()
	malformed_shape["id"] = "0"
	assert_false(
		bridge.capture("gdapi:protocol", [malformed_shape], 31), "non-integer hello id is rejected"
	)
	assert_eq(broker.status().transport, "none", "malformed hello remains disconnected")


func test_hello_requires_generation_metadata() -> void:
	var bridge: RefCounted = DebuggerBridge.new()
	var broker: RefCounted = Broker.new()
	_attach_fake_session(bridge, broker, 37)
	var incomplete := _valid_hello()
	var result: Dictionary = incomplete["result"]
	result.erase("transport")
	assert_false(bridge.capture("gdapi:protocol", [incomplete], 37), "incomplete hello is rejected")
	assert_eq(broker.status().transport, "none", "incomplete hello leaves broker disconnected")
