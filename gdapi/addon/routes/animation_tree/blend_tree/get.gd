@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result: Dictionary = Editor.blend_tree(req.body, "get")
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 409 if result.code == "conflict" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("编辑真实动画混合树 get")
		. param("tree_path", "String", true, "场景内AnimationTree路径", "")
		. example('{"tree_path": "AnimationTree"}')
		. returns("result", {"state": "真实总线或动画图状态"})
	)
