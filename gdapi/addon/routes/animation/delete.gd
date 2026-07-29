@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.remove(req.get_body("player_path", ""), req.get_body("name", "")))

func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("删除动画")
		.param("player_path", "String", true, "AnimationPlayer 节点路径", "")
		.param("name", "String", true, "动画名", "")
		.example("{\"player_path\":\"AnimationPlayer\",\"name\":\"idle\"}")
		.returns("动画删除结果", {"changed": "bool", "undoable": "true"})
	)
