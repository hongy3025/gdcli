## script/validate 路由: 检查 GDScript 语法

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/validate"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := TextEdit.validate_script(path)
	if not result.ok:
		res.error(result.error, result.code, 404)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("校验 .gd 脚本语法")
		.desc("通过 GDScript.reload() 检测语法;不修改文件。返回 valid 与 errors 数组。")
		.param("path", "String", true, "res:// 路径")
		.example("{\"path\":\"res://scripts/broken.gd\"}")
		.returns("校验结果", {
			"ok": "bool",
			"valid": "bool, 语法是否通过",
			"errors": "Array<{line,column,message}>",
			"path": "String",
			"undoable": "bool, false",
		})
	)
