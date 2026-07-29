@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/eval_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "runtime/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var gate := Policy.new().authorize("runtime_eval", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"force": req.get_body("force", false)}, false, gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var broker = Engine.get_meta("gdapi_runtime_broker", null)
	if broker == null or not broker.has_method("request"):
		res.error("runtime is not connected", ErrorCodes.CONFLICT, 409)
		return
	var source := String(req.get_body("source", ""))
	var inputs: Dictionary = req.get_body("inputs", {})
	var result := Service.execute(source, inputs, Policy.new().settings("runtime_eval"))
	if not result.ok:
		AuditLog.record(ROUTE, "dangerous", {"force": true}, false, result.code)
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	AuditLog.record(ROUTE, "dangerous", {"force": true, "type": result.type}, true, "")
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的运行时表达式")
		. desc("使用与 editor/eval 相同的固定输入语法；运行时未连接时返回 conflict。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "允许的输入值")
		. param("force", "bool", true, "确认执行")
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
		. example('{"source":"1+1","force":true}')
	)
