@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.clear(req.get_body("layer_path", ""), req.get_body("force", false)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("清空 TileMapLayer").param("layer_path", "String", true, "TileMapLayer 路径", "").param("force", "bool", true, "确认清空", "").example("{\"layer_path\":\"TileMapLayer\",\"force\":true}").returns("清空结果", {"undoable":"true"})
