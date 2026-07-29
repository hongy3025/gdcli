@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/export_service.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.run(req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, 400, out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受控项目导出")
		. param("preset", "String", true, "预设名")
		. param("path", "String", true, "项目内输出路径")
		. param("force", "bool", true, "允许覆盖")
		. returns(
			"导出 artifact", {"ok": "bool", "path": "String", "size": "int", "sha256": "String"}
		)
		. example('{"preset":"M5 PCK","path":"res://build/m5.pck","force":true}')
	)
