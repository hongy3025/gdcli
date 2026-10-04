@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.info(req.get_body("layer_path", "")))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查询 TileMapLayer 信息")
		. param("layer_path", "String", true, "TileMapLayer 路径", "")
		. example('{"layer_path":"TileMapLayer"}')
		. returns("图层信息", {"used_cell_count": "int"})
	)
