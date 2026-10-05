@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.create(req.get_body("node_path", null), req.get_body("type", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建并赋值受支持的材质")
		. mutates()
		. param("node_path", "String", true, "目标 CanvasItem 节点（场景内相对或 /root/<场景根>/... 绝对）", "")
		. param("type", "CanvasItemMaterial | StandardMaterial2D", true, "受支持材质类型", "")
		. example('{"node_path":"Sprite","type":"CanvasItemMaterial"}')
		. returns("创建结果", {"changed": "bool", "undoable": "bool, true"})
	)
