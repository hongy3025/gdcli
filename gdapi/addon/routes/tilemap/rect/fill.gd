@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.fill_rect(req.get_body("layer_path", ""), req.get_body("from", null), req.get_body("to", null), int(req.get_body("source_id", -1)), req.get_body("atlas_coords", null), int(req.get_body("alternative", 0))))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 400)
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("填充 TileMap 矩形").param("layer_path", "String", true, "TileMapLayer 路径", "").param("from", "Vector2i", true, "起点", "").param("to", "Vector2i", true, "终点", "").example("{\"layer_path\":\"TileMapLayer\",\"from\":{\"x\":0,\"y\":0},\"to\":{\"x\":1,\"y\":1}}").returns("填充结果", {"count":"int", "undoable":"true"})
