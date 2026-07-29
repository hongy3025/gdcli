@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.analyze("script_errors", req.body))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("检查 GDScript 语法错误").returns("脚本错误发现", {"ok":"bool", "items":"Array", "total":"int"}).example("{\"roots\":[\"res://fixtures\"]}")

