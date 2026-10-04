@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Service := preload("res://addons/gdapi/runtime/services/bulk_file_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "filesystem/batch/replace"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := Service.replace(req.body)
	AuditLog.record(
		ROUTE,
		"dangerous",
		{"dry_run": req.get_body("dry_run", false)},
		out.ok,
		String(out.get("code", ""))
	)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code), out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("可验证计划的批量文本替换")
		. mutates()
		. desc("计划包含源文件哈希；应用前源文件变化会返回 conflict。")
		. param("root", "String", true, "扫描根目录")
		. param("find", "String", true, "字面搜索文本")
		. param("replace", "String", true, "替换文本")
		. param("regex", "bool", false, "保留字段；当前仅支持字面模式")
		. param("dry_run", "bool", true, "仅规划")
		. param("plan_hash", "String", false, "计划哈希")
		. returns("替换结果", {"plan_hash": "String", "files": "int", "replacements": "int"})
		. example('{"root":"res://bulk","find":"old","replace":"new","dry_run":true}')
	)
