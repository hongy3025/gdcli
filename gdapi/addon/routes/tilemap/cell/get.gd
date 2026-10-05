@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.get_cell(req.get_body("layer_path", ""), req.get_body("cell", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("读取 TileMap 单元格")
		. param("layer_path", "String", true, "TileMapLayer 路径（场景内相对或 /root/<场景根>/... 绝对）", "")
		. param("cell", "Vector2i", true, "单元格坐标", "")
		. example('{"layer_path":"TileMapLayer","cell":{"x":0,"y":0}}')
		. returns("单元格信息", {"source_id": "int"})
	)
