@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.assign(req.get_body("node_path", null), req.get_body("path", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("通过 UndoRedo 赋值项目材质")
		. mutates()
		. param("node_path", "String", true, "目标节点", "")
		. param("path", "String", true, "Material 的 res:// 路径", "")
		. example('{"node_path":"Sprite","path":"res://materials/sprite.tres"}')
		. returns("赋值结果", {"path": "String", "undoable": "bool, true"})
	)
