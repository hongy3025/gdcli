@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Service := preload("res://addons/gdapi/runtime/services/process_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "process/run"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var checked := Service.validate(req.body)
	if not checked.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"executable": req.get_body("executable", "")}, false, checked.code
		)
		res.error(checked.error, checked.code, ErrorCodes.http_status(checked.code))
		return
	res.audit_summary("dangerous", {"executable": checked.executable})
	var started := Service.start(checked, res)
	if not started.ok:
		AuditLog.record(ROUTE, "dangerous", {"executable": checked.executable}, false, started.code)
		res.error(started.error, started.code, ErrorCodes.http_status(started.code))
		return
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if (
		plugin == null
		or not plugin.register_deferred_task(
			{
				"response": res,
				"deadline_ms": Time.get_ticks_msec() + checked.timeout_ms + 1000,
				"tick": func(now): return Service.tick(started.state, now),
				"cancel": func(reason): Service.cancel(started.state, reason),
				"state": started.state,
			}
		)
	):
		Service.cancel(started.state, "registration failed")
		AuditLog.record(
			ROUTE, "dangerous", {"executable": checked.executable}, false, ErrorCodes.GODOT_ERROR
		)
		res.error("process task could not be registered", ErrorCodes.GODOT_ERROR, 500)
		return


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行无 shell 的受限外部进程")
		. mutates()
		. desc("executable 与 argv 原样传递，不经过 shell；timeout 上限 60s、输出上限 1 MiB")
		. param("executable", "String", true, "可执行文件路径")
		. param("args", "Array[String]", false, "原样 argv")
		. param("cwd", "String", false, "项目目录")
		. param("timeout_ms", "int", false, "超时毫秒数")
		. param("max_output_bytes", "int", false, "stdout/stderr 合计上限")
		. returns(
			"进程结果",
			{
				"exit_code": "int",
				"timed_out": "bool",
				"stdout": "String",
				"stderr": "String",
				"truncated": "bool",
				"undoable": "false"
			}
		)
		. example('{"executable":"python","args":["--version"]}')
	)
