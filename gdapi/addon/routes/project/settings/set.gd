@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.set_setting(String(req.get_body("name", "")), req.get_body("value"))
	if out.ok: res.json(out)
	else: res.error(out.error, out.code)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("写入项目设置").param("name", "String", true, "设置名").param("value", "Variant", true, "设置值").returns("变更结果", {"ok":"bool", "changed":"bool", "undoable":"bool"}).example("{\"name\":\"application/config/name\",\"value\":\"Demo\"}")

