@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.create_shape(
			req.get_body("body_path", null), req.get_body("shape", null), req.get_body("size", null)
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
		. make("创建 2D 碰撞形状")
		. mutates()
		. desc("给物理体挂 CollisionShape2D；shape 支持 rectangle/circle/capsule，接入 UndoRedo。")
		. param("body_path", "String", true, "物理体节点路径")
		. param("shape", "String", true, "形状类型 rectangle|circle|capsule")
		. param("size", "Variant", true, "尺寸（rectangle 为 Vector2，circle/capsule 为数值）")
		. example(
			(
				'{"body_path":"/root/PhysicsDomain/Wall","shape":"rectangle",'
				+ '"size":{"type":"Vector2","value":[4.0,2.0]}}'
			)
		)
		. returns("shape", {"undoable": "true"})
	)
