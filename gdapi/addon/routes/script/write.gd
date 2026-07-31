## script/write 路由: 完整覆盖写入脚本

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEditService := preload("res://addons/gdapi/runtime/services/text_edit.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "script/write"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var content: String = req.get_body("content", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := TextEditService.write_script(path, content, ROUTE)
	if not result.ok:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("覆盖写入 .gd 脚本文件")
		. desc("与 script/create 等价;目标存在直接覆盖。M2 中不允许任意 patch,使用 /patch 行级替换。")
		. param("path", "String", true, "目标 res:// 路径")
		. param("content", "String", true, "完整脚本内容")
		. example('{"path":"res://scripts/player.gd","content":"..."}')
		. returns(
			"写入结果",
			{
				"ok": "bool",
				"changed": "bool",
				"written": "bool",
				"saved": "bool",
				"undoable": "bool, false",
				"path": "String",
				"bytes": "int",
			}
		)
	)
