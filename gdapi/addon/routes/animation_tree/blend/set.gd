@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_tree_editor.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var decoded := Codec.decode(req.get_body("value", null))
	if not decoded.ok:
		res.error(decoded.error, "invalid_param", 400)
		return
	var result := Editor.set_blend(
		req.get_body("tree_path", ""), req.get_body("parameter", ""), decoded.value
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 AnimationTree blend")
		. mutates()
		. param("tree_path", "String", true, "AnimationTree 路径", "")
		. param("parameter", "String", true, "parameters/*/blend_position", "")
		. param("value", "Variant", true, "blend 值", "")
		. example(
			'{"tree_path":"AnimationTree","parameter":"parameters/idle/blend_position","value":0.5}'
		)
		. returns("设置结果", {"undoable": "true", "parameter": "String"})
	)
