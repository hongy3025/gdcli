@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.setting(String(req.get_body("name", "")))
	if out.ok: res.json(out)
	else: res.error(out.error, out.code)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("读取项目设置").param("name", "String", true, "设置名").returns("设置值", {"ok":"bool", "name":"String", "value":"Variant"}).example("{\"name\":\"application/config/name\"}")

