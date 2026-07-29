@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.add_autoload(
		String(req.get_body("name", "")),
		String(req.get_body("path", "")),
		bool(req.get_body("singleton", true))
	)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("添加自动加载").returns("变更结果", {"ok": "bool", "undoable": "bool"}).example(
		'{"name":"State","path":"res://fixtures/state.gd"}'
	)
