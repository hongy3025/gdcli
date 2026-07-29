@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.add_action(String(req.get_body("action", "")), float(req.get_body("deadzone", 0.5)))
	if out.ok: res.json(out)
	else: res.error(out.error, out.code)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("添加输入动作").returns("变更结果", {"ok":"bool", "undoable":"bool"}).example("{\"action\":\"temporary\"}")

