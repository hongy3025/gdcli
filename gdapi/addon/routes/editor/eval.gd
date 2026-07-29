@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/eval_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var gate := Policy.new().authorize("editor_eval", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"force": req.get_body("force", false)}, false, gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var result := Service.execute(
		String(req.get_body("source", "")),
		req.get_body("inputs", {}),
		Policy.new().settings("editor_eval")
	)
	if not result.ok:
		AuditLog.record(ROUTE, "dangerous", {"force": true}, false, result.code)
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	AuditLog.record(ROUTE, "dangerous", {"force": true, "type": result.type}, true, "")
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的无副作用编辑器表达式")
		. desc("仅允许固定输入和受支持的 Variant 类型；必须显式启用策略并 force:true。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "允许的输入值")
		. param("force", "bool", true, "确认执行")
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
		. example('{"source":"origin + delta","inputs":{},"force":true}')
	)
