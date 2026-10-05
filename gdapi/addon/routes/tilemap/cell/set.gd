@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_cell(
			req.get_body("layer_path", ""),
			req.get_body("cell", null),
			int(req.get_body("source_id", -1)),
			req.get_body("atlas_coords", null),
			int(req.get_body("alternative", 0))
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 TileMap 单元格")
		. mutates()
		. param("layer_path", "String", true, "TileMapLayer 路径（场景内相对或 /root/<场景根>/... 绝对）", "")
		. param("cell", "Vector2i", true, "单元格坐标", "")
		. param("source_id", "int", true, "TileSet source", "")
		. param("atlas_coords", "Vector2i", true, "atlas 坐标", "")
		. example(
			'{"layer_path":"TileMapLayer","cell":{"x":0,"y":0},"source_id":0,"atlas_coords":{"x":0,"y":0}}'
		)
		. returns("设置结果", {"undoable": "true"})
	)
