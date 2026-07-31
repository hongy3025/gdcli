@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.list_buses())


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("列出音频总线").desc("返回当前 AudioServer 的全部总线名（排序后）。").returns(
		"buses", {"buses": "Array<String>", "undoable": "false"}
	)
