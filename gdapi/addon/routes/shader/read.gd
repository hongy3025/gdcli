@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.read(req.get_body("path", null)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("读取项目 Shader 源码").param("path", "String", true, "res:// .gdshader 路径", "").example("{\"path\":\"res://shaders/basic.gdshader\"}").returns("Shader 源码", {"path":"String", "source":"String", "undoable":"bool, false"})
