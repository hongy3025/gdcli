@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/bulk_file_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "filesystem/batch/delete"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var gate := Policy.new().authorize("bulk_files", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"force": req.get_body("force", false)}, false, gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var out := Service.delete(req.body)
	AuditLog.record(
		ROUTE,
		"dangerous",
		{"dry_run": req.get_body("dry_run", false), "count": req.get_body("paths", []).size()},
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
		. make("可恢复的批量删除")
		. desc("先 dry_run 获取 plan_hash，再以 force:true 应用；文件进入 gdapi trash。")
		. param("paths", "Array[String]", true, "项目文件路径")
		. param("dry_run", "bool", true, "仅规划")
		. param("plan_hash", "String", false, "计划哈希")
		. param("force", "bool", true, "确认应用")
		. returns("批量删除结果", {"plan_hash": "String", "deleted": "int", "operation_id": "String"})
		. example('{"paths":["res://a.txt"],"dry_run":true,"force":true}')
	)
