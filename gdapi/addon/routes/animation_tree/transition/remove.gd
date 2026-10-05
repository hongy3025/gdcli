@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.remove_transition(
		String(req.get_body("tree_path", "")),
		String(req.get_body("from", "")),
		String(req.get_body("to", ""))
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("删除动画状态图 transition/remove")
		. mutates()
		. param("tree_path", "String", true, "场景内相对路径或 /root/<场景根>/... 绝对节点路径", "")
		. param("from", "String", true, "起点状态", "")
		. param("to", "String", true, "终点状态", "")
		. example('{"tree_path": "AnimationTree", "from": "Start", "to": "idle"}')
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
