@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.clear(req.get_body("layer_path", "")))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("清空 TileMapLayer")
		. mutates()
		. param("layer_path", "String", true, "TileMapLayer 路径（场景内相对或 /root/<场景根>/... 绝对）", "")
		. example('{"layer_path":"TileMapLayer"}')
		. returns("清空结果", {"undoable": "true"})
	)
