@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/ui_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.build_layout(req.get_body("node_path", null), req.get_body("layout", null)))


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("构建固定 UI 布局")
		. param("node_path", "String", true, "Control 路径", "")
		. param("layout", "String", true, "full_rect 或 center", "")
		. example('{"node_path":"Button","layout":"center"}')
		. returns("layout", {"undoable": "true"})
	)
