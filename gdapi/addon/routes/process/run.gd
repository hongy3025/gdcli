@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/process_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "process/run"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var policy := Policy.new()
	var gate := policy.authorize("process", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(
			ROUTE,
			"dangerous",
			{"executable": req.get_body("executable", ""), "force": req.get_body("force", false)},
			false,
			gate.code
		)
		res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code))
		return
	var checked := Service.validate(req.body, policy.settings("process"))
	if not checked.ok:
		AuditLog.record(
			ROUTE, "dangerous", {"executable": req.get_body("executable", "")}, false, checked.code
		)
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
				"tick": func(now): return Service.tick(started.state, now),
				"cancel": func(reason): Service.cancel(started.state, reason)
			}
		)
	):
		Service.cancel(started.state, "registration failed")
		res.error("process task could not be registered", ErrorCodes.GODOT_ERROR, 500)
		return
	AuditLog.record(
		ROUTE,
		"dangerous",
		{
			"executable": checked.executable,
			"arg_count": checked.args.size(),
			"cwd": req.get_body("cwd", "res://")
		},
		true,
		""
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行无 shell 的受限外部进程")
		. desc("executable 与 argv 原样传递，不经过 shell；需要策略允许且 force:true。")
		. param("executable", "String", true, "允许的可执行文件绝对路径")
		. param("args", "Array[String]", false, "原样 argv")
		. param("cwd", "String", false, "策略允许的项目目录")
		. param("timeout_ms", "int", false, "超时毫秒数")
		. param("max_output_bytes", "int", false, "stdout/stderr 合计上限")
		. param("force", "bool", true, "确认执行")
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
		. example('{"executable":"python","args":["--version"],"force":true}')
	)
