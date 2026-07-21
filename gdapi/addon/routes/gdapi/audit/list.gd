@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", ErrorCodes.GODOT_ERROR, 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	var since: int = int(req.get_body("since", 0))
	var limit: int = int(req.get_body("limit", 100))
	if limit < 1:
		limit = 1
	if limit > 1000:
		limit = 1000
	res.json({"ok": true, "entries": plugin.get_audit_since(since, limit)})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 gdapi 审计日志")
		.desc("返回指定 seq 之后的审计日志条目")
		.param("since", "int", false, "起始 seq，不包含该值", 0)
		.param("limit", "int", false, "最大返回数量，范围 1..1000", 100)
		.example("{\"since\":0,\"limit\":100}")
		.returns("审计日志列表", {"ok":"bool", "entries":"Array"})
	)
