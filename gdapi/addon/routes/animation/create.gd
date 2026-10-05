@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.create(req.get_body("player_path", ""), req.get_body("name", ""))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建动画")
		. mutates()
		. param(
			"player_path", "String", true, "AnimationPlayer 节点路径（场景内相对或 /root/<场景根>/... 绝对）", ""
		)
		. param("name", "String", true, "动画名", "")
		. example('{"player_path":"AnimationPlayer","name":"idle"}')
		. returns("动画创建结果", {"changed": "bool", "undoable": "true", "name": "String"})
	)
