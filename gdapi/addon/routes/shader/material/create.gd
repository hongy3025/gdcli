@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res, Editor.create_material(req.get_body("shader_path", null), req.get_body("path", null))
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 ShaderMaterial 资源")
		. param("shader_path", "String", true, "源 .gdshader", "")
		. param("path", "String", true, "目标 .tres/.res", "")
		. example(
			'{"shader_path":"res://shaders/basic.gdshader","path":"res://materials/basic.tres"}'
		)
		. returns("创建结果", {"path": "String", "saved": "bool", "undoable": "bool, false"})
	)
