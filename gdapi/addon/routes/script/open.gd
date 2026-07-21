## script/open 路由: 打开脚本到 Script Editor (可定位行列)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/open"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var line: int = int(req.get_body("line", -1))
	var column: int = int(req.get_body("column", -1))
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := TextEdit.open_script(path, line, column)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("把 .gd 脚本加载到 Script Editor")
		.desc("line/column 为 1-based;省略时只加载脚本不定位。")
		.param("path", "String", true, "res:// 路径")
		.param("line", "int", false, "1-based 行号,省略仅打开", "-1")
		.param("column", "int", false, "1-based 列号", "-1")
		.example("{\"path\":\"res://scripts/player.gd\",\"line\":2,\"column\":1}")
		.returns("open 结果", {
			"ok": "bool",
			"changed": "bool, 始终为 false",
			"undoable": "bool, false",
			"path": "String",
			"line": "int",
			"column": "int",
		})
	)
