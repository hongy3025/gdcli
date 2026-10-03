@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.get_bus(req.get_body("name", null))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("读取真实音频总线属性与效果")
		. param("name", "String", true, "总线名", "")
		. example('{"name": "Master"}')
		. returns("result", {"state": "真实总线或动画图状态"})
	)
