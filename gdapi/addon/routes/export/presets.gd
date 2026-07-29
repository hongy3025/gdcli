@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/export_service.gd")
func handle(_req: GdApiRequest, res: GdApiResponse) -> void: res.json(S.presets())
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("发现导出预设").returns("导出预设", {"ok":"bool", "presets":"Array"}).example("{}")

