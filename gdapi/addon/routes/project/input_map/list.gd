@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({"ok": true, "items": S.input_actions(req.body)})


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("列出输入动作").returns("动作及事件", {"ok": "bool", "items": "Array"}).example(
		"{}"
	)
