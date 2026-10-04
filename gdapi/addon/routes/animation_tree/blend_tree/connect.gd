@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.blend_tree(req.body, "connect")
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("编辑真实动画混合树 connect")
		. mutates()
		. param("tree_path", "String", true, "场景内AnimationTree路径", "")
		. param("input_node", "String", true, "接收输入的节点", "")
		. param("input_index", "int", true, "输入端口索引", "")
		. param("output_node", "String", true, "提供输出的节点，拒绝悬空与循环", "")
		. example(
			(
				'{"tree_path": "AnimationTree", "input_node": "output", '
				+ '"input_index": 0, "output_node": "blend"}'
			)
		)
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
