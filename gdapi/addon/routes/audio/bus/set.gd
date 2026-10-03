@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.set_bus(req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("事务设置音频总线属性")
		. mutates()
		. param("name", "String", true, "总线名", "")
		. param("properties", "Object", true, "volume_db/mute/solo/bypass/send，send拒绝循环", "")
		. example(
			'{"name": "SFX", "properties": {"volume_db": -6, "mute": false, "send": "Master"}}'
		)
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
