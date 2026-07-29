@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.duplicate_material(
			req.get_body("node_path", null),
			req.get_body("path", null),
			req.get_body("force", false)
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(
			result.error,
			result.code,
			403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400
		)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("复制材质到新的项目资源")
		. param("node_path", "String", true, "源材质节点", "")
		. param("path", "String", true, "不同的 res:// .tres/.res 目标", "")
		. param("force", "bool", false, "覆盖已有文件需要 true", false)
		. example('{"node_path":"Sprite","path":"res://materials/sprite_copy.tres"}')
		. returns("复制结果", {"path": "String", "saved": "bool", "undoable": "bool, false"})
	)
