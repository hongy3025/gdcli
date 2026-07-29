@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/ui_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.text_set(req.get_body("node_path", null), req.get_body("text", null)))


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置控件文本")
		. param("node_path", "String", true, "Control 路径", "")
		. param("text", "String", true, "文本", "")
		. example('{"node_path":"Button","text":"M4"}')
		. returns("text", {"undoable": "true"})
	)
