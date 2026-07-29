@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_item(
			req.get_body("path", null),
			"font_size",
			req.get_body("type", "Control"),
			req.get_body("item", null),
			req.get_body("value", null),
			req.get_body("force", false)
		)
	)


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 400)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("设置 Theme 字体大小").returns("theme", {"undoable": "false"})
