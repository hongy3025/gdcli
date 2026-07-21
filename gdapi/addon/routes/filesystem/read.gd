## filesystem/read 路由: 读取文件文本内容

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/read"

const MAX_BYTES := 4 * 1024 * 1024

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", ErrorCodes.MISSING_PARAM)
		return
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		res.error(checked.error, checked.code, 400)
		return
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if not FileAccess.file_exists(abs_path):
		res.error("file not found: " + checked.path, ErrorCodes.NOT_FOUND, 404)
		return
	var bytes := FileAccess.get_file_as_bytes(abs_path)
	if bytes.size() > MAX_BYTES:
		res.error("file too large for text read (max 4 MiB)", ErrorCodes.INVALID_PARAM, 400)
		return
	res.json({
		"ok": true,
		"path": checked.path,
		"content": bytes.get_string_from_utf8(),
		"bytes": bytes.size(),
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取文件文本内容")
		.desc("超过 4 MiB 返回 invalid_param;二进制文件不可预测,推荐走 res:// 二进制资源。")
		.param("path", "String", true, "res:// 文件路径")
		.example("{\"path\":\"res://scripts/player.gd\"}")
		.returns("文本内容", {
			"ok": "bool",
			"path": "String",
			"content": "String",
			"bytes": "int",
			"undoable": "bool, false",
		})
	)
