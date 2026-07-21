## script/patch 路由: 行级 patch (1-based 闭区间)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/patch"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var first: int = int(req.get_body("start_line", -1))
	var last: int = int(req.get_body("end_line", -1))
	var text: String = req.get_body("text", "")
	var force: bool = req.get_body("force", false)
	if path == "":
		res.error("path is required", "missing_param")
		return
	if first < 1 or last < first:
		res.error("start_line must be >= 1 and <= end_line", "invalid_param")
		return
	var result := TextEdit.patch_script(path, first, last, text, force)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("替换脚本中 [start_line, end_line] 行区间")
		.desc("1-based 闭区间替换;text 支持多行,通过换行拆分。写入磁盘使用 temp file + rename 原子化;无变化时仍写入需 force:true。")
		.param("path", "String", true, "res:// 路径")
		.param("start_line", "int", true, "起始行号 (1-based, inclusive)")
		.param("end_line", "int", true, "结束行号 (1-based, inclusive)")
		.param("text", "String", true, "替换内容")
		.param("force", "bool", false, "无变化时也写盘需 true", "false")
		.example("{\"path\":\"res://scripts/player.gd\",\"start_line\":2,\"end_line\":2,\"text\":\"var speed := 20\",\"force\":true}")
		.returns("patch 结果", {
			"ok": "bool",
			"changed": "bool",
			"saved": "bool",
			"undoable": "bool, false",
			"path": "String",
			"first": "int",
			"last": "int",
		})
	)
