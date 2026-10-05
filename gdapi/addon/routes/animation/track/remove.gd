@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.remove_track(
			req.get_body("player_path", ""),
			req.get_body("name", ""),
			int(req.get_body("track_index", -1))
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
		. make("删除动画 track")
		. mutates()
		. param("player_path", "String", true, "AnimationPlayer 路径（场景内相对或 /root/<场景根>/... 绝对）", "")
		. param("name", "String", true, "动画名", "")
		. param("track_index", "int", true, "track 索引", "")
		. example('{"player_path":"AnimationPlayer","name":"idle","track_index":0}')
		. returns("track 结果", {"track_index": "int", "undoable": "true"})
	)
