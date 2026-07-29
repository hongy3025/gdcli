@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_layer(
			req.get_body("node_path", null),
			req.get_body("property", null),
			req.get_body("value", null)
		)
	)


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 400)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("设置 2D 碰撞层").returns("layer", {"undoable": "true"})
