@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "gdapi/audit/clear"


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", ErrorCodes.GODOT_ERROR, 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	plugin.clear_audit()
	AuditLog.record(ROUTE, "dangerous", {}, true, "")
	res.json({"ok": true, "cleared": true, "changed": true, "undoable": false})


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("清空 gdapi 审计日志").desc("清空内存审计缓冲区。").returns(
		"清空结果", {"ok": "bool", "cleared": "bool", "changed": "bool", "undoable": "bool"}
	)
