@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.class_detail(String(req.get_body("class", "")))
	if out.ok: res.json(out)
	else: res.error(out.error, out.code)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("查询 ClassDB 类详情").param("class", "String", true, "类名").returns("类详情", {"ok":"bool", "name":"String", "parent":"String", "enum_names":"Array"}).example("{\"class\":\"Node2D\"}")
