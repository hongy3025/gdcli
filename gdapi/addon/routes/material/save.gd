@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/material_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.save(req.get_body("node_path", null), req.get_body("path", null), req.get_body("force", false)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("保存节点材质到项目资源").param("node_path", "String", true, "目标节点", "").param("path", "String", true, "目标 res:// .tres/.res 路径", "").param("force", "bool", false, "覆盖已有文件需要 true", false).example("{\"node_path\":\"Sprite\",\"path\":\"res://materials/sprite.tres\"}").returns("保存结果", {"path":"String", "saved":"bool", "undoable":"bool, false"})
