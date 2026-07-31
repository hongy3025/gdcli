@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


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
		res.error(r.error, r.code, ErrorCodes.http_status(r.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 2D 碰撞层")
		. desc("设置节点 collision_layer/collision_mask 属性，接入 UndoRedo。")
		. param("node_path", "String", true, "目标节点路径")
		. param("property", "String", true, "collision_layer 或 collision_mask")
		. param("value", "int", true, "层位掩码")
		. example('{"node_path":"/root/PhysicsDomain/Wall","property":"collision_layer","value":1}')
		. returns("layer", {"undoable": "true"})
	)
