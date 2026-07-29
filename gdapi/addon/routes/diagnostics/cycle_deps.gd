@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.analyze("cycle_deps", req.body))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("检测资源依赖环").returns("依赖环发现", {"ok":"bool", "items":"Array", "total":"int"}).example("{\"roots\":[\"res://fixtures\"]}")

