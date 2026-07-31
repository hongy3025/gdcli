@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Service := preload("res://addons/gdapi/runtime/services/network_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "network/http_request"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var checked := Service.validate(req.body)
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"url": req.get_body("url", "")}, false, checked.code)
		res.error(checked.error, checked.code, ErrorCodes.http_status(checked.code))
		return
	var started := Service.start(checked, res)
	if not started.ok:
		res.error(started.error, started.code, ErrorCodes.http_status(started.code))
		return
	var terminal := func(outcome):
		AuditLog.record(ROUTE, "dangerous", {"url": checked.url}, outcome.ok, outcome.code)
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if (
		plugin == null
		or not plugin.register_deferred_task(
			{
				"response": res,
				"deadline_ms": Time.get_ticks_msec() + checked.timeout_ms + 1000,
				"tick": func(_now): return bool(started.state.done),
				"cancel": func(_reason): started.state.node.cancel_request(),
				"finish": terminal
			}
		)
	):
		started.state.node.cancel_request()
		res.error("network task could not be registered", ErrorCodes.GODOT_ERROR, 500)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("HTTP 请求")
		. desc("仅 http/https，下载上限 4 MiB、重定向 ≤5、超时 ≤60s。")
		. param("url", "String", true, "目标 URL")
		. param("method", "String", false, "GET 或 HEAD")
		. param("headers", "Dictionary", false, "请求头")
		. param("timeout_ms", "int", false, "超时")
		. param("max_response_bytes", "int", false, "响应上限")
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
		. example('{"url":"https://example.com/"}')
	)
