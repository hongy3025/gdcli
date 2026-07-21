## resource/deps 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/deps"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := ResourceEditor.deps(path)
	if not result.ok:
		res.error(result.error, result.code, 404)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取资源的依赖列表")
		.desc("通过 ResourceLoader.get_dependencies 获取依赖。返回的 items 是被依赖文件路径。")
		.param("path", "String", true, "res:// 资源路径")
		.example("{\"path\":\"res://scenes/main.tscn\"}")
		.returns("deps", {
			"ok": "bool",
			"path": "String",
			"items": "Array<String>",
			"undoable": "bool, false",
		})
	)
