@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")
const ROUTE := "runtime/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var gate := Policy.new().authorize("runtime_eval", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"force": req.get_body("force", false)}, false, gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var settings: Dictionary = Policy.new().settings("runtime_eval")
	if typeof(req.body.get("inputs", {})) == TYPE_DICTIONARY:
		req.body["allowed_input_keys"] = settings.get("allowed_input_keys", [])
	dispatch_versioned(req, res, "eval", Protocol.VERSION_V2, true, ROUTE)


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
