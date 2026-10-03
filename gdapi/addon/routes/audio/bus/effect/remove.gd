@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.effect(req.body, "remove")
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("音频总线效果 remove")
		. mutates()
		. param("name", "String", true, "总线名", "")
		. param("slot", "int", true, "效果槽索引，add默认末尾", "")
		. example('{"name": "SFX", "slot": 0}')
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
