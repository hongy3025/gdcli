@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var found := Editor.player(req.get_body("player_path", ""))
	if not found.ok:
		res.error(found.error, found.code, 400)
		return
	var name: String = req.get_body("name", "")
	if not found.player.has_animation(name):
		res.error("animation not found", "not_found", 404)
		return
	found.player.play(name)
	res.json({"ok": true, "changed": true, "undoable": false, "name": name})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("播放动画")
		. mutates()
		. param(
			"player_path", "String", true, "AnimationPlayer 节点路径（场景内相对或 /root/<场景根>/... 绝对）", ""
		)
		. param("name", "String", true, "动画名", "")
		. example('{"player_path":"AnimationPlayer","name":"idle"}')
		. returns("播放结果", {"changed": "bool", "undoable": "false"})
	)
