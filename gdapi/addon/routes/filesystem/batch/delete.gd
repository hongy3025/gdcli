@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Service := preload("res://addons/gdapi/runtime/services/bulk_file_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "filesystem/batch/delete"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
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
		. desc("先 dry_run 获取 plan_hash，再以 plan_hash 应用；文件进入 gdapi trash。")
		. param("paths", "Array[String]", true, "项目文件路径")
		. param("dry_run", "bool", true, "仅规划")
		. param("plan_hash", "String", false, "计划哈希")
		. returns("批量删除结果", {"plan_hash": "String", "deleted": "int", "operation_id": "String"})
		. example('{"paths":["res://a.txt"],"dry_run":true}')
	)
