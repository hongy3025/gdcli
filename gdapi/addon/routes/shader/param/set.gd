@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_param(
			req.get_body("path", null), req.get_body("name", null), req.get_body("value", null)
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置已声明的 ShaderMaterial uniform")
		. param("path", "String", true, "ShaderMaterial .tres/.res", "")
		. param("name", "String", true, "Shader 中声明的 uniform", "")
		. param("value", "Variant", true, "与 uniform 类型精确匹配的值", "")
		. example('{"path":"res://materials/basic.tres","name":"strength","value":0.75}')
		. returns("参数设置结果", {"path": "String", "name": "String", "undoable": "bool, false"})
	)
