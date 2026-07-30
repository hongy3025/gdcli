@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.list_buses())


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("列出音频总线").returns(
		"buses", {"buses": "Array<String>", "undoable": "false"}
	)
