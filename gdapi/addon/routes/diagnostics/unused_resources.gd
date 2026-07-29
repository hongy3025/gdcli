@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.analyze("unused_resources", req.body))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("查找未引用资源").returns("只读发现", {"ok":"bool", "items":"Array", "total":"int"}).example("{\"roots\":[\"res://\"]}")

