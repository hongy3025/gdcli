@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.add_transition(req.get_body("tree_path", ""), req.get_body("from", ""), req.get_body("to", ""))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)

func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("添加 AnimationTree transition").param("tree_path", "String", true, "AnimationTree 路径", "").param("from", "String", true, "源 state", "").param("to", "String", true, "目标 state", "").example("{\"tree_path\":\"AnimationTree\",\"from\":\"idle\",\"to\":\"run\"}").returns("transition 结果", {"changed": "bool", "undoable": "true"})
