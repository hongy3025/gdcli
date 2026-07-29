@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/bulk_file_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "filesystem/batch/recover"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var gate := Policy.new().authorize("bulk_files", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"force": req.get_body("force", false)}, false, gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var out := Service.recover(String(req.get_body("operation_id", "")))
	AuditLog.record(
		ROUTE,
		"dangerous",
		{"operation_id": req.get_body("operation_id", "")},
		out.ok,
		String(out.get("code", ""))
	)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("恢复批量删除操作")
		. desc("从 gdapi trash 恢复文件，不覆盖现有目标。")
		. param("operation_id", "String", true, "删除返回的操作 ID")
		. param("force", "bool", true, "确认恢复")
		. returns("恢复结果", {"restored": "int", "changed": "bool"})
		. example('{"operation_id":"123-456","force":true}')
	)
