@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.info(req.get_body("node_path", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查询节点材质")
		. param("node_path", "String", true, "目标节点（场景内相对或 /root/<场景根>/... 绝对）", "")
		. example('{"node_path":"Sprite"}')
		. returns(
			"材质信息",
			{
				"class": "String",
				"path": "String",
				"properties": "Dictionary",
				"undoable": "bool, false"
			}
		)
	)
