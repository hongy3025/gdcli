@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/ui_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_anchor(
			req.get_body("node_path", null),
			req.get_body("anchors", {}),
			req.get_body("offsets", {})
		)
	)


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置控件锚点")
		. mutates()
		. param("node_path", "String", true, "Control 路径", "")
		. param("anchors", "Dictionary", true, "left/top/right/bottom", "")
		. param("offsets", "Dictionary", false, "可选偏移", "{}")
		. example('{"node_path":"Button","anchors":{"left":0,"top":0,"right":1,"bottom":1}}')
		. returns("anchor", {"undoable": "true"})
	)
