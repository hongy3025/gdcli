@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var found := Editor.player(req.get_body("player_path", ""))
	if not found.ok:
		res.error(found.error, found.code, 400)
		return
	found.player.stop()
	res.json({"ok": true, "changed": true, "undoable": false})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("停止动画")
		. param("player_path", "String", true, "AnimationPlayer 节点路径", "")
		. example('{"player_path":"AnimationPlayer"}')
		. returns("停止结果", {"changed": "bool", "undoable": "false"})
	)
