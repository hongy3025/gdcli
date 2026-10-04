@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.add_track(
			req.get_body("player_path", ""), req.get_body("name", ""), req.get_body("path", "")
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("添加动画 value track")
		. mutates()
		. param("player_path", "String", true, "AnimationPlayer 路径", "")
		. param("name", "String", true, "动画名", "")
		. param("path", "String", true, "目标 NodePath", "")
		. example('{"player_path":"AnimationPlayer","name":"idle","path":"Sprite:position"}')
		. returns("track 结果", {"track_index": "int", "undoable": "true"})
	)
