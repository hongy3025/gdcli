@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json(S.health(req.body))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("返回项目诊断健康状态")
		. returns("健康和发现计数", {"ok": "bool", "godot": "String", "findings": "Dictionary"})
		. example("{}")
	)
