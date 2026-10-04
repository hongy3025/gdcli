@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.uniforms(req.get_body("path", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出 Shader uniform")
		. param("path", "String", true, "res:// .gdshader 路径", "")
		. example('{"path":"res://shaders/basic.gdshader"}')
		. returns(
			"uniform 列表", {"uniforms": "Array<{name,type,default}>", "undoable": "bool, false"}
		)
	)
