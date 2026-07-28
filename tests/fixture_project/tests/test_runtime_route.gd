## GdApiRuntimeRoute 单元测试
##
## 使用内存 broker/server/plugin 验证 HTTP adapter 的行为边界，不启动真实游戏进程。

@tool
extends SceneTree

const Request := preload("res://addons/gdapi/runtime/request.gd")
const Response := preload("res://addons/gdapi/runtime/response.gd")
const RuntimeRoute := preload("res://addons/gdapi/runtime/runtime_route.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

class FakeServer extends RefCounted:
	var responses: Array = []

	func send_response(id: int, status: int, _headers: Dictionary, body: PackedByteArray) -> void:
		responses.append({"id": id, "status": status, "body": JSON.parse_string(body.get_string_from_utf8())})

class FakeBroker extends RefCounted:
	var calls: Array = []
	var next_reply: Dictionary = {"ok": true, "result": {}}
	var duplicate_callback: bool = false

	func request(op: String, payload: Dictionary, timeout_ms: int, callback: Callable) -> int:
		calls.append({"op": op, "payload": payload.duplicate(true), "timeout_ms": timeout_ms})
		callback.call(next_reply.duplicate(true))
		if duplicate_callback:
			callback.call(next_reply.duplicate(true))
		return calls.size()

class FakePlugin extends RefCounted:
	var events: Array = []

	func audit_event(event: Dictionary) -> void:
		events.append(event.duplicate(true))

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeRoute tests...\n")
	test_disconnected_broker_is_conflict()
	test_timeout_defaults_caps_and_rejects_invalid_values()
	test_error_codes_map_to_stable_http_statuses()
	test_success_flattens_runtime_result_into_ok_envelope()
	test_mutation_success_adds_contract_fields_and_audits()
	test_mutation_rejection_is_audited_with_redacted_payload()
	test_redact_recurses_through_nested_values()
	test_redact_summarizes_base64_and_large_arrays()
	test_response_is_sent_exactly_once()
	Engine.remove_meta("gdapi_runtime_broker")
	Engine.remove_meta("gdapi_plugin")

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_eq(actual: Variant, expected: Variant, context: String = "") -> void:
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

func _request(payload: Dictionary = {}) -> Request:
	return Request.new({
		"method": "POST",
		"path": "/runtime/test",
		"body": JSON.stringify(payload).to_utf8_buffer(),
	})

func _response(server: FakeServer) -> Response:
	return Response.new(server, 17)

func _dispatch(payload: Dictionary, broker: FakeBroker, mutation: bool = false) -> FakeServer:
	Engine.set_meta("gdapi_runtime_broker", broker)
	var server := FakeServer.new()
	RuntimeRoute.new().dispatch(_request(payload), _response(server), "runtime/test", mutation)
	return server

func _last_response(server: FakeServer) -> Dictionary:
	return server.responses.back()

func test_disconnected_broker_is_conflict() -> void:
	Engine.remove_meta("gdapi_runtime_broker")
	var server := FakeServer.new()
	RuntimeRoute.new().dispatch(_request(), _response(server), "runtime/test")
	assert_eq(server.responses.size(), 1, "disconnected broker sends one response")
	assert_eq(_last_response(server).status, 409, "disconnected broker maps to conflict")
	assert_eq(_last_response(server).body.code, ErrorCodes.CONFLICT, "disconnected broker code")

func test_timeout_defaults_caps_and_rejects_invalid_values() -> void:
	var adapter := RuntimeRoute.new()
	assert_eq(adapter.operation_timeout(_request()), 5000, "missing timeout uses default")
	assert_eq(adapter.operation_timeout(_request({"timeout_ms": 99999})), 25000, "timeout is capped")
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": true, "result": {"ready": true}}
	var capped := _dispatch({"timeout_ms": 99999}, broker)
	assert_eq(broker.calls[0].timeout_ms, 26000, "broker receives operation timeout plus grace")
	assert_eq(broker.calls[0].payload.timeout_ms, 25000, "runtime receives capped operation timeout")
	var invalid_server := _dispatch({"timeout_ms": "slow"}, broker)
	assert_eq(_last_response(invalid_server).status, 400, "invalid timeout is invalid_param")
	assert_eq(broker.calls.size(), 1, "invalid timeout never reaches broker")

func test_error_codes_map_to_stable_http_statuses() -> void:
	var expected := {
		"missing_param": 400,
		"invalid_param": 400,
		"invalid_path": 400,
		"permission_denied": 403,
		"unsafe_operation": 403,
		"not_found": 404,
		"conflict": 409,
		"timeout": 408,
		"not_supported": 501,
		"godot_error": 500,
	}
	for code in expected:
		var broker := FakeBroker.new()
		broker.next_reply = {"ok": false, "code": code, "error": "failed"}
		var server := _dispatch({}, broker)
		assert_eq(_last_response(server).status, expected[code], code + " status")

func test_success_flattens_runtime_result_into_ok_envelope() -> void:
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": true, "result": {"value": 7, "node_path": "/root/RuntimeMain"}}
	var server := _dispatch({}, broker)
	assert_eq(_last_response(server).status, 200, "success status")
	assert_eq(_last_response(server).body.ok, true, "success envelope ok")
	assert_eq(_last_response(server).body.value, 7.0, "success envelope result")
	assert_eq(_last_response(server).body.node_path, "/root/RuntimeMain", "success envelope path")

func test_mutation_success_adds_contract_fields_and_audits() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": true, "result": {"changed": true, "target": "ProbeTarget"}}
	var server := _dispatch({"node_path": "/root/RuntimeMain/ProbeTarget"}, broker, true)
	assert_eq(_last_response(server).body.ok, true, "mutation success ok")
	assert_eq(_last_response(server).body.changed, true, "mutation changed")
	assert_eq(_last_response(server).body.undoable, false, "runtime mutation is not undoable")
	assert_eq(_last_response(server).body.operation, "runtime/test", "mutation operation summary")
	assert_eq(plugin.events.size(), 1, "mutation success is audited")
	assert_eq(plugin.events[0].ok, true, "successful audit result")

func test_mutation_rejection_is_audited_with_redacted_payload() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": false, "code": "permission_denied", "error": "denied"}
	var server := _dispatch({"token": "do-not-log", "nested": {"password": "also-secret"}}, broker, true)
	assert_eq(_last_response(server).status, 403, "mutation rejection status")
	assert_eq(plugin.events.size(), 1, "mutation rejection is audited")
	var summary: Dictionary = plugin.events[0].summary
	assert_eq(summary.payload.token, "[REDACTED]", "top-level secret is redacted")
	assert_eq(summary.payload.nested.password, "[REDACTED]", "nested secret is redacted")
	assert_eq(summary.result.code, "permission_denied", "rejection result is included")

func test_redact_recurses_through_nested_values() -> void:
	var value := {"headers": [{"Authorization": "Bearer secret"}], "data": {"cookie": "private"}}
	var redacted: Variant = RuntimeRoute.new().redact(value)
	assert_eq(redacted.headers[0].Authorization, "[REDACTED]", "redacts secrets in arrays")
	assert_eq(redacted.data.cookie, "[REDACTED]", "redacts secrets in dictionaries")

func test_redact_summarizes_base64_and_large_arrays() -> void:
	var items: Array = []
	for i in range(40):
		items.append(i)
	var redacted: Dictionary = RuntimeRoute.new().redact({
		"data_base64": "a".repeat(128),
		"frames": items,
	})
	assert_eq(redacted.data_base64.type, "base64", "base64 type summary")
	assert_eq(redacted.data_base64.size, 128, "base64 size summary")
	assert_eq(redacted.frames.type, "array", "large array type summary")
	assert_eq(redacted.frames.size, 40, "large array size summary")
	assert_false(redacted.frames is Array, "large array is not copied into audit")

func test_response_is_sent_exactly_once() -> void:
	var broker := FakeBroker.new()
	broker.duplicate_callback = true
	broker.next_reply = {"ok": true, "result": {"ready": true}}
	var server := _dispatch({}, broker)
	assert_eq(server.responses.size(), 1, "duplicate callback sends one response")
