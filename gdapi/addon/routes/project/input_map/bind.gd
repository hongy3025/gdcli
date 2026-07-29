@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.bind(String(req.get_body("action", "")), req.get_body("event", {}))
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("绑定输入事件").returns("变更结果", {"ok": "bool", "undoable": "bool"}).example(
		'{"action":"ui_accept","event":{"type":"InputEventKey","keycode":1}}'
	)
