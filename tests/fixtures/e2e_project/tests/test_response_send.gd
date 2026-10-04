@tool
extends SceneTree

const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")

var passed := 0
var failed := 0


class FakeServer:
	var accept_response := false
	var sent_count := 0
	var last_body := PackedByteArray()

	func send_response(_id: int, _status: int, _headers: Dictionary, body: PackedByteArray) -> bool:
		sent_count += 1
		last_body = body
		return accept_response


class FakeCancelledRequestControl:
	extends RefCounted
	var reason := "disconnected"

	func cancellation_reason() -> String:
		return reason


class FakePlugin:
	extends RefCounted
	var events: Array[Dictionary] = []

	func audit_event(event: Dictionary) -> void:
		events.append(event)


func _init() -> void:
	test_rejected_send_does_not_complete_audit()
	test_accepted_send_completes_audit()
	test_disconnected_failure_completes_audit()
	test_committed_operation_remains_successful_after_cancellation()
	test_json_controls_are_valid_for_success_and_error_responses()
	test_json_controls_are_valid_for_cancellation_response()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_rejected_send_does_not_complete_audit() -> void:
	var server := FakeServer.new()
	var response := GdApiResponse.new(server, 7, null)
	response.bind_audit("scene/open", true)
	response.json({"ok": true, "changed": true})
	assert_eq(server.sent_count, 1, "attempted one response")
	assert_eq(response.audit_context.completed, false, "failed send leaves audit incomplete")


func test_accepted_send_completes_audit() -> void:
	var server := FakeServer.new()
	server.accept_response = true
	var response := GdApiResponse.new(server, 8, null)
	response.bind_audit("scene/open", true)
	response.json({"ok": true, "changed": true})
	assert_eq(server.sent_count, 1, "attempted one accepted response")
	assert_eq(response.audit_context.completed, true, "accepted send completes audit")


func test_json_controls_are_valid_for_success_and_error_responses() -> void:
	var controls := ""
	for codepoint in range(0x20):
		controls += String.chr(codepoint)
	var server := FakeServer.new()
	var response := GdApiResponse.new(server, 11, null)
	response.json({"stdout": controls, "stderr": controls})
	assert_json_body_preserves_controls(server.last_body, controls, "success response")

	server = FakeServer.new()
	response = GdApiResponse.new(server, 12, null)
	response.error(controls, "error", 400, {"details": controls})
	assert_json_body_preserves_controls(server.last_body, controls, "error response")


func test_json_controls_are_valid_for_cancellation_response() -> void:
	var controls := ""
	for codepoint in range(0x20):
		controls += String.chr(codepoint)
	var server := FakeServer.new()
	var control := FakeCancelledRequestControl.new()
	control.reason = controls
	var response := GdApiResponse.new(server, 13, control)
	response.json({"stdout": "discarded"})
	assert_json_body_preserves_controls(
		server.last_body, "request cancelled: " + controls, "cancellation response"
	)


func assert_json_body_preserves_controls(
	body: PackedByteArray, expected: String, context: String
) -> void:
	var serialized := body.get_string_from_utf8()
	var contains_raw_control := false
	for index in range(serialized.length()):
		if serialized.unicode_at(index) < 0x20:
			contains_raw_control = true
			break
	assert_eq(contains_raw_control, false, context + " has no raw C0 controls")
	assert_eq(serialized.contains("\\v"), false, context + " does not emit nonstandard \\\\v")
	var decoded: Variant = JSON.parse_string(serialized)
	assert_eq(decoded != null, true, context + " parses as JSON")
	if decoded.has("stdout"):
		assert_eq(decoded.stdout, expected, context + " preserves stdout")
		assert_eq(decoded.stderr, expected, context + " preserves stderr")
	else:
		assert_eq(decoded.error, expected, context + " preserves error text")


func test_committed_operation_remains_successful_after_cancellation() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var server := FakeServer.new()
	var response := GdApiResponse.new(server, 10, FakeCancelledRequestControl.new())
	var result := {"ok": true, "changed": true, "path": "res://scenes/target.tscn"}
	response.bind_audit("scene/open", true)
	response.mark_operation_committed(result)
	response.json(result)
	assert_eq(server.sent_count, 1, "committed operation still attempts a response")
	assert_eq(response.payload, result, "cancellation does not replace committed success")
	assert_eq(response.audit_context.completed, true, "disconnected commit completes audit")
	assert_eq(plugin.events.size(), 1, "committed operation emits one audit event")
	assert_eq(plugin.events[0].ok, true, "committed scene open is audited as successful")
	Engine.remove_meta("gdapi_plugin")


func test_disconnected_failure_completes_audit() -> void:
	var plugin := FakePlugin.new()
	Engine.set_meta("gdapi_plugin", plugin)
	var response := GdApiResponse.new(FakeServer.new(), 9, null)
	response.bind_audit("network/http_request", true)
	response.audit_summary("dangerous", {"url": "http://example.com/"})
	response.error("request cancelled: disconnected", "conflict", 409)
	assert_eq(response.audit_context.completed, false, "rejected send has not completed audit")
	response.complete_audit_failure("request cancelled: disconnected", "conflict", 409)
	response.complete_audit_failure("duplicate", "conflict", 409)
	assert_eq(response.audit_context.completed, true, "terminal failure completes audit")
	assert_eq(plugin.events.size(), 1, "terminal failure emits exactly one audit event")
	assert_eq(plugin.events[0].route, "network/http_request", "failure keeps route identity")
	assert_eq(plugin.events[0].ok, false, "failure is not audited as success")
	assert_eq(plugin.events[0].code, "conflict", "failure code is preserved")
	Engine.remove_meta("gdapi_plugin")


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
