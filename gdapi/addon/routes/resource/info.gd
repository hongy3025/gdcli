## resource/info 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/info"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := ResourceEditor.info(path)
	if not result.ok:
		res.error(result.error, result.code, 404)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取资源元数据")
		.desc("返回 uid、class、local_to_scene 与可序列化属性。")
		.param("path", "String", true, "res:// 资源路径")
		.example("{\"path\":\"res://resources/player_data.tres\"}")
		.returns("info", {
			"ok": "bool",
			"path": "String",
			"uid": "String",
			"class": "String",
			"script": "String",
			"local_to_scene": "bool",
			"properties": "Dictionary<String, Variant>",
			"undoable": "bool, false",
		})
	)
