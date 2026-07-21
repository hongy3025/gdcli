@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "gdapi/audit/clear"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var force: bool = bool(req.get_body("force", false))
	if not ErrorCodes.require_force(res, force, ROUTE):
		AuditLog.record(ROUTE, "dangerous", {"force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", ErrorCodes.GODOT_ERROR, 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	plugin.clear_audit()
	AuditLog.record(ROUTE, "dangerous", {"force": true}, true, "")
	res.json({"ok": true, "cleared": true, "changed": true, "undoable": false})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("清空 gdapi 审计日志")
		.desc("危险操作；必须传 force:true")
		.param("force", "bool", true, "必须为 true 才会清空审计日志", false)
		.example("{\"force\":true}")
		.returns("清空结果", {"ok":"bool", "cleared":"bool", "changed":"bool", "undoable":"bool"})
	)
