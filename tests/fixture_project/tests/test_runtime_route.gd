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


class FakeServer:
	extends RefCounted
	var responses: Array = []

	func send_response(id: int, status: int, _headers: Dictionary, body: PackedByteArray) -> void:
		responses.append(
			{"id": id, "status": status, "body": JSON.parse_string(body.get_string_from_utf8())}
		)


class FakeBroker:
	extends RefCounted
	var calls: Array = []
	var next_reply: Dictionary = {"ok": true, "result": {}}
	var duplicate_callback: bool = false

	func request(op: String, payload: Dictionary, timeout_ms: int, callback: Callable) -> int:
		calls.append({"op": op, "payload": payload.duplicate(true), "timeout_ms": timeout_ms})
		callback.call(next_reply.duplicate(true))
		if duplicate_callback:
			callback.call(next_reply.duplicate(true))
		return calls.size()


class FakePlugin:
	extends RefCounted
	var events: Array = []

	func audit_event(event: Dictionary) -> void:
		events.append(event.duplicate(true))


var passed := 0
var failed := 0


func _init() -> void:
	print("Running GdApiRuntimeRoute tests...\n")
	test_disconnected_broker_is_conflict()
	test_dispatch_requires_exact_runtime_path_and_operation()
	test_dispatch_rejects_unknown_path_params_before_broker()
	test_mutation_boundary_failures_are_audited()
	test_oversized_request_is_rejected_before_broker_and_audited()
	test_timeout_defaults_caps_and_rejects_invalid_values()
	test_error_codes_map_to_stable_http_statuses()
	test_success_flattens_runtime_result_into_ok_envelope()
	test_mutation_success_adds_contract_fields_and_audits()
	test_mutation_rejection_is_audited_with_redacted_payload()
	test_redact_recurses_through_nested_values()
	test_redact_covers_auth_key_variants_and_short_values()
	test_redact_summarizes_base64_and_large_arrays()
	test_audit_summary_redacts_aliases_and_bounds_unclassified_values()
	test_redact_bounds_keys_and_unclassified_variants()
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
	return _request_at("/runtime/test", payload)


func _request_at(path: String, payload: Dictionary = {}) -> Request:
	return _request_raw(path, JSON.stringify(payload))


func _request_raw(path: String, raw_body: String) -> Request:
	return (
		Request
		. new(
			{
				"method": "POST",
				"path": path,
				"body": raw_body.to_utf8_buffer(),
			}
		)
	)


func _response(server: FakeServer) -> Response:
	return Response.new(server, 17)


func _dispatch(payload: Dictionary, broker: FakeBroker, mutation: bool = false) -> FakeServer:
	return _dispatch_request(_request(payload), broker, "runtime/test", mutation)


func _dispatch_request(
	req: Request, broker: FakeBroker, op: String, mutation: bool = false
) -> FakeServer:
	Engine.set_meta("gdapi_runtime_broker", broker)
	var server := FakeServer.new()
	RuntimeRoute.new().dispatch(req, _response(server), op, mutation)
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


func test_dispatch_requires_exact_runtime_path_and_operation() -> void:
	var broker := FakeBroker.new()
	var mismatch := _dispatch_request(_request_at("/runtime/other"), broker, "runtime/test")
	assert_eq(_last_response(mismatch).status, 400, "path/op mismatch is invalid_param")
	assert_eq(broker.calls.size(), 0, "path/op mismatch does not reach broker")
	var arbitrary := _dispatch_request(
		_request_at("/editor/scene/save"), broker, "editor/scene/save"
	)
	assert_eq(_last_response(arbitrary).status, 400, "arbitrary operation is rejected")
	assert_eq(broker.calls.size(), 0, "arbitrary operation does not reach broker")
	var empty_path := _dispatch_request(_request_at(""), broker, "runtime/test")
	assert_eq(_last_response(empty_path).status, 400, "empty request path is rejected")


func test_dispatch_rejects_unknown_path_params_before_broker() -> void:
	var broker := FakeBroker.new()
	var req := _request()
	req.params = {"unexpected": "value"}
	var server := _dispatch_request(req, broker, "runtime/test")
	assert_eq(_last_response(server).status, 400, "unknown static-route params are rejected")
	assert_eq(broker.calls.size(), 0, "malformed params do not reach broker")


func test_mutation_boundary_failures_are_audited() -> void:
	_assert_mutation_boundary_audited(
		_request_at("/runtime/other"), "runtime/test", "path mismatch"
	)
	_assert_mutation_boundary_audited(
		_request_at("/runtime/"), "runtime/", "empty operation suffix"
	)
	var params_request := _request()
	params_request.params = {"unexpected": "value"}
	_assert_mutation_boundary_audited(params_request, "runtime/test", "unknown params")
	_assert_mutation_boundary_audited(
		_request_raw("/runtime/test", "[]"), "runtime/test", "invalid body"
	)
	_assert_mutation_boundary_audited(
		_request({"timeout_ms": "slow"}), "runtime/test", "invalid timeout"
	)


func test_oversized_request_is_rejected_before_broker_and_audited() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var broker := FakeBroker.new()
	var secret := "task16-route-secret"
	var request := _request(
		{
			"authorization": secret,
			"blob": "x".repeat(Protocol.MAX_MESSAGE_BYTES),
		}
	)
	var server := _dispatch_request(request, broker, "runtime/test", true)
	assert_eq(_last_response(server).status, 400, "oversized route request is invalid_param")
	assert_eq(
		_last_response(server).body.get("code", ""),
		ErrorCodes.INVALID_PARAM,
		"oversized route request preserves stable code"
	)
	assert_eq(broker.calls.size(), 0, "oversized route request never reaches broker")
	assert_eq(plugin.events.size(), 1, "oversized mutation request is audited once")
	if plugin.events.size() == 1:
		assert_false(
			JSON.stringify(plugin.events[0]).contains(secret),
			"oversized mutation audit does not contain the secret value"
		)


func _assert_mutation_boundary_audited(req: Request, op: String, context: String) -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var broker := FakeBroker.new()
	var server := _dispatch_request(req, broker, op, true)
	assert_eq(_last_response(server).status, 400, context + " status")
	assert_eq(plugin.events.size(), 1, context + " audit count")
	if plugin.events.size() == 1:
		assert_eq(plugin.events[0].ok, false, context + " audit rejection")
		assert_eq(plugin.events[0].code, ErrorCodes.INVALID_PARAM, context + " audit code")
	assert_eq(broker.calls.size(), 0, context + " does not reach broker")


func test_timeout_defaults_caps_and_rejects_invalid_values() -> void:
	var adapter := RuntimeRoute.new()
	assert_eq(adapter.operation_timeout(_request()), 5000, "missing timeout uses default")
	assert_eq(
		adapter.operation_timeout(_request({"timeout_ms": 5000.0})),
		5000,
		"exact integral float timeout is accepted"
	)
	assert_eq(
		adapter.operation_timeout(_request({"timeout_ms": 25000})),
		25000,
		"maximum operation timeout is accepted"
	)
	assert_eq(
		adapter.operation_timeout(_request({"timeout_ms": 99999})), 25000, "timeout is capped"
	)
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": true, "result": {"ready": true}}
	_dispatch({}, broker)
	assert_eq(broker.calls[0].payload.timeout_ms, 5000, "default timeout reaches runtime payload")
	var capped := _dispatch({"timeout_ms": 99999}, broker)
	assert_eq(broker.calls[1].timeout_ms, 26000, "broker receives operation timeout plus grace")
	assert_eq(
		broker.calls[1].payload.timeout_ms, 25000, "runtime receives capped operation timeout"
	)
	for invalid in [5000.0000001, -0.0000001]:
		assert_eq(
			adapter.operation_timeout(_request({"timeout_ms": invalid})),
			-1,
			"unsafe timeout %s is rejected" % invalid
		)
	for invalid in [NAN, INF, -INF]:
		var direct_request := _request()
		direct_request.body = {"timeout_ms": invalid}
		assert_eq(
			adapter.operation_timeout(direct_request),
			-1,
			"non-finite timeout %s is rejected" % invalid
		)
	var invalid_server := _dispatch({"timeout_ms": "slow"}, broker)
	assert_eq(_last_response(invalid_server).status, 400, "invalid timeout is invalid_param")
	assert_eq(broker.calls.size(), 2, "invalid timeout never reaches broker")


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
	var server := _dispatch(
		{"token": "do-not-log", "nested": {"password": "also-secret"}}, broker, true
	)
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


func test_redact_covers_auth_key_variants_and_short_values() -> void:
	var bearer := "Bearer task16-auth-secret"
	var short_secret := "Q7"
	var redacted: Dictionary = (
		RuntimeRoute
		. new()
		. redact(
			{
				"auth": bearer,
				"nested":
				[
					{"AUTH_HEADER": short_secret},
					{"Auth-Header": bearer},
					{"auth.header": short_secret},
					{"AuthHeader": bearer},
				],
			}
		)
	)
	assert_eq(redacted.auth, "[REDACTED]", "auth is redacted")
	for entry in redacted.nested:
		assert_eq(entry.values()[0], "[REDACTED]", "auth header spelling is redacted")
	var serialized := JSON.stringify(redacted)
	assert_false(serialized.contains(bearer), "Bearer value does not appear in audit summary")
	assert_false(
		serialized.contains(short_secret), "short auth value does not appear in audit summary"
	)


func test_redact_summarizes_base64_and_large_arrays() -> void:
	var items: Array = []
	for i in range(40):
		items.append(i)
	var redacted: Dictionary = (
		RuntimeRoute
		. new()
		. redact(
			{
				"data_base64": "a".repeat(128),
				"frames": items,
			}
		)
	)
	assert_eq(redacted.data_base64.type, "base64", "base64 type summary")
	assert_eq(redacted.data_base64.size, 128, "base64 size summary")
	assert_eq(redacted.frames.type, "array", "large array type summary")
	assert_eq(redacted.frames.size, 40, "large array size summary")
	assert_false(redacted.frames is Array, "large array is not copied into audit")


func test_audit_summary_redacts_aliases_and_bounds_unclassified_values() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var large_dict: Dictionary = {}
	for i in range(40):
		large_dict["key_%d" % i] = i
	var blob := PackedByteArray()
	blob.resize(64)
	var broker := FakeBroker.new()
	broker.next_reply = {"ok": true, "result": {"changed": true}}
	_dispatch(
		{
			"api_token": "do-not-log",
			"nested": {"client_secret": "also-secret"},
			"large_string": "x".repeat(512),
			"large_dict": large_dict,
			"blob": blob,
		},
		broker,
		true
	)
	var payload: Dictionary = plugin.events[0].summary.payload
	assert_eq(payload.api_token, "[REDACTED]", "api_token alias is redacted")
	assert_eq(payload.nested.client_secret, "[REDACTED]", "client_secret alias is redacted")
	var large_string: Variant = payload.get("large_string", null)
	assert_eq(typeof(large_string), TYPE_DICTIONARY, "large string has bounded summary")
	if typeof(large_string) == TYPE_DICTIONARY and large_string.has("type"):
		assert_eq(large_string.type, "string", "large string has bounded type summary")
		assert_eq(large_string.size, 512, "large string has bounded size summary")
	var large_dict_summary: Variant = payload.get("large_dict", null)
	assert_eq(typeof(large_dict_summary), TYPE_DICTIONARY, "large dictionary has bounded summary")
	if typeof(large_dict_summary) == TYPE_DICTIONARY and large_dict_summary.has("type"):
		assert_eq(
			large_dict_summary.type, "dictionary", "large dictionary has bounded type summary"
		)
		assert_eq(large_dict_summary.size, 40, "large dictionary has bounded size summary")
		assert_true(large_dict_summary.keys.size() <= 16, "large dictionary keys are bounded")
	var blob_summary: Variant = RuntimeRoute.new().redact(blob)
	assert_eq(typeof(blob_summary), TYPE_DICTIONARY, "packed bytes have bounded summary")
	if typeof(blob_summary) == TYPE_DICTIONARY and blob_summary.has("type"):
		assert_eq(blob_summary.type, "bytes", "packed bytes have type summary")
		assert_eq(blob_summary.size, 64, "packed bytes have size summary")


func test_redact_bounds_keys_and_unclassified_variants() -> void:
	var long_key := "key_" + "x".repeat(100)
	var key_summary: Dictionary = RuntimeRoute.new().redact({long_key: "value"})
	var bounded_key := String(key_summary.keys()[0])
	assert_true(bounded_key.length() <= 64, "dictionary key length is bounded")
	assert_eq(key_summary[bounded_key], "value", "bounded key keeps scalar value")
	var packed_vectors := PackedVector2Array()
	packed_vectors.append(Vector2(1, 2))
	var unclassified := [
		Vector2(1, 2),
		StringName("name"),
		NodePath("/root"),
		RefCounted.new(),
		Callable(),
		packed_vectors
	]
	for value in unclassified:
		var summary: Variant = RuntimeRoute.new().redact(value)
		assert_eq(typeof(summary), TYPE_DICTIONARY, "unclassified variant is summarized")
		if typeof(summary) == TYPE_DICTIONARY:
			assert_true(summary.has("type"), "unclassified variant has type")


func test_response_is_sent_exactly_once() -> void:
	var broker := FakeBroker.new()
	broker.duplicate_callback = true
	broker.next_reply = {"ok": true, "result": {"ready": true}}
	var server := _dispatch({}, broker)
	assert_eq(server.responses.size(), 1, "duplicate callback sends one response")
