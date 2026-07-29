@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: res.json({"ok":true, "items":S.settings(req.body)})
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("列出项目设置").returns("设置名", {"ok":"bool", "items":"Array"}).example("{}")

