@tool
class_name GdApiAuditLog
extends RefCounted

static func record(route: String, safety: String, summary: Dictionary, ok: bool, code: String = "") -> void:
	if not Engine.has_meta("gdapi_plugin"):
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	if not plugin or not plugin.has_method("audit_event"):
		return
	plugin.audit_event({
		"route": route,
		"safety": safety,
		"summary": summary,
		"ok": ok,
		"code": code,
	})

static func record_runtime(route: String, payload: Variant, result: Variant, ok: bool, code: String = "") -> void:
	record(route, "runtime", {
		"operation": route,
		"payload": payload,
		"result": result,
	}, ok, code)
