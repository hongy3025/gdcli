## resource/reimport 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/reimport"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var paths_v: Variant = req.get_body("paths", [])
	if typeof(paths_v) != TYPE_ARRAY or paths_v.is_empty():
		res.error("paths must be a non-empty array", "invalid_param")
		return
	var result := ResourceEditor.reimport(paths_v)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重新导入一组资源")
		.desc("通过 EditorInterface.get_resource_filesystem().reimport_files 触发导入。")
		.param("paths", "Array<String>", true, "res:// 资源路径列表")
		.example("{\"paths\":[\"res://icon.svg\"]}")
		.returns("reimport", {
			"ok": "bool",
			"changed": "bool",
			"reimported": "Array<String>",
			"undoable": "bool, false",
		})
	)
