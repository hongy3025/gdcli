@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.stop(req.get_body("node_path", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("停止音频")
		. param("node_path", "String", true, "AudioStreamPlayer 路径", "")
		. example('{"node_path":"AudioPlayer"}')
		. returns("stop", {"playing": "bool", "undoable": "false"})
	)
