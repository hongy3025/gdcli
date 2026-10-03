@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.effect(req.body, "add")
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("音频总线效果 add")
		. mutates()
		. param("name", "String", true, "总线名", "")
		. param("slot", "int", false, "效果槽索引，add默认末尾", "")
		. param("type", "String", true, "原生AudioEffect类", "")
		. param("parameters", "Object", false, "效果属性，严格类型与范围校验", "")
		. param("enabled", "bool", false, "效果启用状态", "")
		. example(
			'{"name": "SFX", "slot": 0, "type": "AudioEffectAmplify", '
			+ '"parameters": {"volume_db": -3}, "enabled": true}'
		)
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
