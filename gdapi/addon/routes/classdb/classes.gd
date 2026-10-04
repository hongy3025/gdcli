@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json(S.classes(req.body))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出 Godot ClassDB 类")
		. returns("排序分页的类名", {"ok": "bool", "items": "Array[String]"})
		. example('{"filter":"Node"}')
	)
