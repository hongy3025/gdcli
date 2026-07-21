## script/read 路由: 读取 GDScript 文本

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/read"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := TextEdit.read_script(path)
	if not result.ok:
		res.error(result.error, result.code, 404)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 .gd 脚本文件内容")
		.desc("仅允许 res:// 路径,通过 PathGuard 校验。返回 content 与 bytes。")
		.param("path", "String", true, "res:// 路径下的脚本文件")
		.example("{\"path\":\"res://scripts/player.gd\"}")
		.returns("script 内容", {
			"ok": "bool",
			"path": "String",
			"content": "String, 脚本全文",
			"bytes": "int, 字节数",
			"undoable": "bool, false",
		})
	)
