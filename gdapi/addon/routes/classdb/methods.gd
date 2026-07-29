@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json(S.members(String(req.get_body("class", "")), "methods", req.body))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查询 ClassDB 方法")
		. param("class", "String", true, "类名")
		. returns("方法列表", {"ok": "bool", "items": "Array"})
		. example('{"class":"Node2D"}')
	)
