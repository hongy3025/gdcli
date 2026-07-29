@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_property(
			req.get_body("node_path", null),
			req.get_body("property", null),
			req.get_body("value", null)
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置受支持材质属性")
		. param("node_path", "String", true, "目标节点", "")
		. param("property", "String", true, "稳定白名单中的属性", "")
		. param("value", "Variant", true, "与属性类型精确匹配的值", "")
		. example('{"node_path":"Sprite","property":"blend_mode","value":1}')
		. returns("设置结果", {"changed": "bool", "undoable": "bool, true"})
	)
