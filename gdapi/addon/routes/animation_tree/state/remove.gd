@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.remove_state(
		String(req.get_body("tree_path", "")), String(req.get_body("name", ""))
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("删除动画状态图 state/remove")
		. mutates()
		. param("tree_path", "String", true, "场景内AnimationTree路径", "")
		. param("name", "String", true, "要删除的状态，禁止Start/End", "")
		. example('{"tree_path": "AnimationTree", "name": "idle"}')
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
