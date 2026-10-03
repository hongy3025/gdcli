@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.create_body(
			req.get_body("parent_path", null),
			req.get_body("name", null),
			req.get_body("type", null)
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
		. make("创建 2D 物理体")
		. mutates()
		. desc("在当前编辑场景中创建 StaticBody2D/CharacterBody2D/RigidBody2D 并挂到 parent_path 下，接入 UndoRedo。")
		. param("parent_path", "String", true, "父节点绝对路径")
		. param("name", "String", true, "新节点名称")
		. param("type", "String", false, "物理体类型，缺省值见 physics_editor.gd", "")
		. example('{"parent_path":"/root/PhysicsDomain","name":"Wall","type":"StaticBody2D"}')
		. returns("body", {"undoable": "true"})
	)
