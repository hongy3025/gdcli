@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/eval_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "editor/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.execute(String(req.get_body("source", "")), req.get_body("inputs", {}))
	if not result.ok:
		AuditLog.record(ROUTE, "dangerous", {}, false, result.code)
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	AuditLog.record(ROUTE, "dangerous", {"type": result.type}, true, "")
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的无副作用编辑器表达式")
		. mutates()
		. desc("仅允许固定输入和受支持的 Variant 类型；源码上限 16 KiB，禁止语句/成员访问/赋值。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "输入值（任意 key，值需为受支持的 Variant 类型）")
		. example(
			(
				'{"source":"origin + delta","inputs":'
				+ '{"origin":{"type":"Vector2","value":[1.0,2.0]},'
				+ '"delta":{"type":"Vector2","value":[3.0,4.0]}}}'
			)
		)
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
	)
