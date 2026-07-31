@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/export_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var target := String(req.body.get("preset", ""))
	var output_path := String(req.body.get("path", ""))
	var out := S.run(req.body)
	if out.ok:
		AuditLog.record(
			"export/run", "dangerous", {"target": target, "output_path": output_path}, true, ""
		)
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code), out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受控项目导出")
		. param("preset", "String", true, "预设名")
		. param("path", "String", true, "项目内输出路径")
		. returns(
			"导出 artifact", {"ok": "bool", "path": "String", "size": "int", "sha256": "String"}
		)
		. example('{"preset":"M5 PCK","path":"res://build/m5.pck"}')
	)
