@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.add_bus(req.get_body("name", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("添加音频总线")
		. param("name", "String", true, "唯一总线名", "")
		. example('{"name":"SFX"}')
		. returns("bus", {"changed": "bool", "undoable": "false"})
	)
