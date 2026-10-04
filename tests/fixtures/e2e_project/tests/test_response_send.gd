@tool
extends SceneTree

const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")

var passed := 0
var failed := 0


class FakeServer:
	extends RefCounted
	var accept_response := false
	var sent_count := 0

	func send_response(
		_id: int, _status: int, _headers: Dictionary, _body: PackedByteArray
	) -> bool:
		sent_count += 1
		return accept_response


class FakeCancelledRequestControl:
	extends RefCounted

	func cancellation_reason() -> String:
		return "disconnected"


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
