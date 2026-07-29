@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.members(String(req.get_body("class", "")), "signals", req.body))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("查询 ClassDB 信号").param("class", "String", true, "类名").returns("信号列表", {"ok":"bool", "items":"Array"}).example("{\"class\":\"Node2D\"}")

