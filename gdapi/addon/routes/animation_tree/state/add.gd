@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.add_state(req.get_body("tree_path", ""), req.get_body("name", ""))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)

func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("添加 AnimationTree state").param("tree_path", "String", true, "AnimationTree 路径", "").param("name", "String", true, "state 名", "").example("{\"tree_path\":\"AnimationTree\",\"name\":\"idle\"}").returns("state 结果", {"changed": "bool", "undoable": "true"})
