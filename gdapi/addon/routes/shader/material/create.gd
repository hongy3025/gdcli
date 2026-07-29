@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.create_material(req.get_body("shader_path", null), req.get_body("path", null), req.get_body("force", false)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("创建 ShaderMaterial 资源").param("shader_path", "String", true, "源 .gdshader", "").param("path", "String", true, "目标 .tres/.res", "").param("force", "bool", false, "覆盖已有文件需要 true", false).example("{\"shader_path\":\"res://shaders/basic.gdshader\",\"path\":\"res://materials/basic.tres\"}").returns("创建结果", {"path":"String", "saved":"bool", "undoable":"bool, false"})
