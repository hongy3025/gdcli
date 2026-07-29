@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
func handle(_req: GdApiRequest, res: GdApiResponse) -> void: res.json({"ok":true, "autoloads":S.autoloads()})
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("列出自动加载").returns("自动加载", {"ok":"bool", "autoloads":"Array"}).example("{}")

