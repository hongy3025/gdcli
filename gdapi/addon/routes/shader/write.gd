@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.write(req.get_body("path", null), req.get_body("source", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建或覆盖项目 Shader")
		. mutates()
		. param("path", "String", true, "res:// .gdshader 目标", "")
		. param("source", "String", true, "完整 shader 源码", "")
		. example('{"path":"res://shaders/basic.gdshader","source":"shader_type canvas_item;"}')
		. returns("写入结果", {"path": "String", "written": "bool", "undoable": "bool, false"})
	)
