@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.members(String(req.get_body("class", "")), "properties", req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查询 ClassDB 属性")
		. param("class", "String", true, "类名")
		. returns("属性列表", {"ok": "bool", "items": "Array"})
		. example('{"class":"Node2D","filter":"position"}')
	)
