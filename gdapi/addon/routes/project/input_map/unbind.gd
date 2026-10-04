@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.unbind(String(req.get_body("action", "")), req.get_body("event", {}))
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("解除输入事件")
		. mutates()
		. returns("变更结果", {"ok": "bool", "undoable": "bool"})
		. example('{"action":"ui_accept","event":{"type":"InputEventKey","keycode":1}}')
	)
