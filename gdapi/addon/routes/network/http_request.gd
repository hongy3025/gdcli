@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/network_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "network/http_request"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var policy := Policy.new()
	var gate := policy.authorize("network", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE,
			"dangerous",
			{"url": req.get_body("url", ""), "force": req.get_body("force", false)},
			false,
			gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var checked := Service.validate(req.body, policy.settings("network"))
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"url": req.get_body("url", "")}, false, checked.code)
		res.error(checked.error, checked.code, ErrorCodes.http_status(checked.code))
		return
	var started := Service.start(checked, res)
	if not started.ok:
		res.error(started.error, started.code, ErrorCodes.http_status(started.code))
		return
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if (
		plugin == null
		or not plugin.register_deferred_task(
			{
				"response": res,
				"deadline_ms": Time.get_ticks_msec() + checked.timeout_ms + 1000,
				"tick": func(_now): return bool(started.state.done),
				"cancel": func(_reason): started.state.node.cancel_request(),
				"terminal":
				func(outcome):
					AuditLog.record(
						ROUTE, "dangerous", {"url": checked.url}, outcome.ok, outcome.code
					)
			}
		)
	):
		started.state.node.cancel_request()
		res.error("network task could not be registered", ErrorCodes.GODOT_ERROR, 500)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("策略约束的 HTTP 请求")
		. desc("策略必须明确允许 scheme、host、port；默认拒绝私网目标并限制 GET/HEAD。")
		. param("url", "String", true, "目标 URL")
		. param("method", "String", false, "GET 或 HEAD")
		. param("headers", "Dictionary", false, "请求头")
		. param("timeout_ms", "int", false, "超时")
		. param("max_response_bytes", "int", false, "响应上限")
		. param("force", "bool", true, "确认请求")
		. returns(
			"HTTP 结果",
			{
				"status": "int",
				"body_base64": "String",
				"size": "int",
				"sha256": "String",
				"undoable": "false"
			}
		)
		. example('{"url":"https://allowed.example/","force":true}')
	)
