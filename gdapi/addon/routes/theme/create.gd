@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.create(req.get_body("path", null), req.get_body("force", false)))


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, 403 if r.code == "unsafe_operation" else 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 Theme 资源")
		. param("path", "String", true, "项目内 .tres", "")
		. param("force", "bool", false, "覆盖需 true", "false")
		. example('{"path":"res://themes/main.tres"}')
		. returns("theme", {"saved": "true", "undoable": "false"})
	)
