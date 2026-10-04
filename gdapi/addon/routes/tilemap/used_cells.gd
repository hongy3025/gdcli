@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/tilemap_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.used_cells(req.get_body("layer_path", "")))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出 TileMap 已用单元格")
		. param("layer_path", "String", true, "TileMapLayer 路径", "")
		. example('{"layer_path":"TileMapLayer"}')
		. returns("单元格列表", {"cells": "Array"})
	)
