@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/project_config.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.reset(String(req.get_body("name", "")), bool(req.get_body("force", false)))
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code)


func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("删除项目设置").returns("变更结果", {"ok": "bool", "undoable": "bool"}).example(
		'{"name":"application/config/name","force":true}'
	)
