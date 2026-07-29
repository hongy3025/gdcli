@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/classdb_query.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.inheriters(String(req.get_body("class", "")), req.body))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("查询 ClassDB 派生类").param("class", "String", true, "基类名").returns("派生类列表", {"ok":"bool", "items":"Array[String]"}).example("{\"class\":\"Node\"}")

