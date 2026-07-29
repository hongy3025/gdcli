@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.set_param(req.get_body("path", null), req.get_body("name", null), req.get_body("value", null), req.get_body("force", false)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("设置已声明的 ShaderMaterial uniform").param("path", "String", true, "ShaderMaterial .tres/.res", "").param("name", "String", true, "Shader 中声明的 uniform", "").param("value", "Variant", true, "与 uniform 类型精确匹配的值", "").param("force", "bool", false, "持久化参数变更需要 true", false).example("{\"path\":\"res://materials/basic.tres\",\"name\":\"strength\",\"value\":0.75,\"force\":true}").returns("参数设置结果", {"path":"String", "name":"String", "undoable":"bool, false"})
