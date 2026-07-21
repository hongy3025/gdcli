## filesystem/reimport 路由: 重新导入资源

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/reimport"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var paths_v: Variant = req.get_body("paths", [])
	if typeof(paths_v) != TYPE_ARRAY or paths_v.is_empty():
		res.error("paths must be a non-empty array", ErrorCodes.INVALID_PARAM)
		return
	var validated: Array = []
	for raw in paths_v:
		var p := str(raw)
		var checked := PathGuard.validate(p, "write")
		if not checked.ok:
			res.error("invalid path " + p + ": " + checked.error, checked.code, checked.get("status", 400))
			return
		validated.append(checked.path)
	if not Engine.is_editor_hint():
		res.error("filesystem/reimport requires editor", ErrorCodes.NOT_SUPPORTED, 400)
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		res.error("EditorFileSystem unavailable", ErrorCodes.NOT_SUPPORTED, 500)
		return
	fs.reimport_files(validated)
	AuditLog.record(ROUTE, "file", {"paths": validated}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"reimported": validated,
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重新导入一组项目资源")
		.desc("通过 EditorInterface.get_resource_filesystem().reimport_files 触发导入。返回 reimported 路径数组。")
		.param("paths", "Array<String>", true, "res:// 资源路径列表")
		.example("{\"paths\":[\"res://icon.svg\"]}")
		.returns("reimport 结果", {
			"ok": "bool",
			"changed": "bool",
			"reimported": "Array<String>",
			"undoable": "bool, false",
		})
	)
