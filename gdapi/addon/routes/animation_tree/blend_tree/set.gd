@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.blend_tree(req.body, "set")
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("编辑真实动画混合树 set")
		. mutates()
		. param("tree_path", "String", true, "场景内AnimationTree路径", "")
		. param("name", "String", true, "图节点唯一名称，output保留", "")
		. param("properties", "Object", false, "AnimationNode资源属性，如animation/fadein_time", "")
		. param("parameters", "Object", false, "运行参数，如blend_amount/scale/request", "")
		. example(
			'{"tree_path": "AnimationTree", "name": "blend", "parameters": {"blend_amount": 0.5}}'
		)
		. returns("result", {"undoable": "bool", "changed": "bool"})
	)
