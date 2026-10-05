@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res, Editor.duplicate_material(req.get_body("node_path", null), req.get_body("path", null))
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("复制材质到新的项目资源")
		. mutates()
		. param("node_path", "String", true, "源材质节点（场景内相对或 /root/<场景根>/... 绝对）", "")
		. param("path", "String", true, "不同的 res:// .tres/.res 目标", "")
		. example('{"node_path":"Sprite","path":"res://materials/sprite_copy.tres"}')
		. returns("复制结果", {"path": "String", "saved": "bool", "undoable": "bool, false"})
	)
