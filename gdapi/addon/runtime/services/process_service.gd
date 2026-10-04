@tool
class_name GdApiProcessService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const DEFAULT_TIMEOUT_MS := 5000
const MAX_TIMEOUT_MS := 60_000
const DEFAULT_MAX_OUTPUT_BYTES := 65536
const MAX_OUTPUT_BYTES := 1_048_576


static func validate(body: Dictionary) -> Dictionary:
	var executable := String(body.get("executable", ""))
	var args: Array = body.get("args", [])
	if executable.is_empty() or typeof(args) != TYPE_ARRAY:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "executable and args are required"
		}
	for arg in args:
		if typeof(arg) != TYPE_STRING:
			return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "args must be strings"}
	var cwd := String(body.get("cwd", "res://"))
	var checked := PathGuard.validate(cwd, "read")
	if not checked.ok:
		return checked
	var timeout := int(body.get("timeout_ms", DEFAULT_TIMEOUT_MS))
	var cap := int(body.get("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES))
	if timeout <= 0 or timeout > MAX_TIMEOUT_MS:
		return {
			"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "timeout_ms must be in 1..60000"
		}
	if cap <= 0 or cap > MAX_OUTPUT_BYTES:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "max_output_bytes must be in 1..1048576"
		}
	return {
		"ok": true,
		"executable": executable,
		"args": args,
		"cwd": ProjectSettings.globalize_path(checked.path),
		"timeout_ms": timeout,
		"max_output_bytes": cap
	}


static func start(spec: Dictionary, response: GdApiResponse) -> Dictionary:
	var runner = GdApiProcessRunner.create()
	var packed := PackedStringArray(spec.args)
	var id := int(
		runner.start(
			response.request_control,
			spec.executable,
			packed,
			spec.cwd,
			mini(spec.timeout_ms, response.remaining_ms()),
			spec.max_output_bytes
		)
	)
	if id < 0:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "process could not start"}
	var state := {"runner": runner, "id": id, "response": response}
	return {"ok": true, "state": state}


static func tick(state: Dictionary, _now_ms: int) -> bool:
	var result: Dictionary = state.runner.poll(state.id)
	if not bool(result.get("done", false)):
		return false
	var payload := {
		"ok": true,
		"changed": true,
		"undoable": false,
		"exit_code": result.exit_code,
		"timed_out": result.timed_out,
		"cancelled": result.cancelled,
		"stdout": result.stdout,
		"stderr": result.stderr,
		"truncated": result.truncated
	}
	if result.timed_out:
		state["outcome"] = {"ok": false, "code": ErrorCodes.TIMEOUT, "summary": "process timed out"}
		state.response.error("process timed out", ErrorCodes.TIMEOUT, 408)
	elif result.cancelled:
		state["outcome"] = {
			"ok": false, "code": ErrorCodes.CONFLICT, "summary": "process cancelled"
		}
		state.response.error("process cancelled", ErrorCodes.CONFLICT, 409)
	else:
		state["outcome"] = {"ok": true, "code": "", "summary": "process completed"}
		state.response.json(payload)
	return true


static func cancel(state: Dictionary, _reason: String) -> void:
	state.runner.cancel(state.id)
	state["outcome"] = {"ok": false, "code": ErrorCodes.CONFLICT, "summary": "process cancelled"}
