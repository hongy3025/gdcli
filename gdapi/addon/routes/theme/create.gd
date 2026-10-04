@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.create(req.get_body("path", null)))


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, ErrorCodes.http_status(r.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 Theme 资源")
		. mutates()
		. param("path", "String", true, "项目内 .tres", "")
		. example('{"path":"res://resources/theme.tres"}')
		. returns("theme", {"saved": "true", "undoable": "false"})
	)
