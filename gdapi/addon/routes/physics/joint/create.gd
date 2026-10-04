@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.create_joint(
			req.get_body("parent_path", null),
			req.get_body("type", null),
			req.get_body("name", "Joint")
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
		. make("创建 2D 物理关节")
		. mutates()
		. desc(
			"在当前编辑场景中创建 PinJoint2D/GrooveJoint2D/DampedSpringJoint2D 并挂到 parent_path 下，接入 UndoRedo。"
		)
		. param("parent_path", "String", true, "父节点绝对路径")
		. param("type", "String", true, "关节类型")
		. param("name", "String", false, "新节点名称", "Joint")
		. example('{"parent_path":"/root/PhysicsDomain","type":"PinJoint2D","name":"Pivot"}')
		. returns("joint", {"undoable": "true"})
	)
