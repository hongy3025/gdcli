@tool
class_name GdApiProcessService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")

static func validate(body: Dictionary, policy: Dictionary) -> Dictionary:
	var executable := String(body.get("executable", ""))
	var args: Array = body.get("args", [])
	if executable.is_empty() or typeof(args) != TYPE_ARRAY:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "executable and args are required"}
	for arg in args:
		if typeof(arg) != TYPE_STRING: return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "args must be strings"}
	var allowed: Array = policy.get("executables", [])
	if not allowed.has(executable):
		return {"ok": false, "code": ErrorCodes.PERMISSION_DENIED, "error": "executable is not allowed"}
	var cwd := String(body.get("cwd", "res://"))
	var checked := PathGuard.validate(cwd, "read")
	if not checked.ok: return checked
	var roots: Array = policy.get("cwd_roots", [])
	var under_root := false
	for root in roots:
		var normalized := String(root).trim_suffix("/")
		if checked.path == normalized or checked.path.begins_with(normalized + "/"): under_root = true
	if not under_root: return {"ok": false, "code": ErrorCodes.PERMISSION_DENIED, "error": "cwd is outside policy roots"}
	var timeout := int(body.get("timeout_ms", 5000))
	var cap := int(body.get("max_output_bytes", 65536))
	if timeout <= 0 or timeout > int(policy.get("max_timeout_ms", 0)): return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "timeout exceeds policy"}
	if cap <= 0 or cap > int(policy.get("max_output_bytes", 0)): return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "output cap exceeds policy"}
	return {"ok": true, "executable": executable, "args": args, "cwd": ProjectSettings.globalize_path(checked.path), "timeout_ms": timeout, "max_output_bytes": cap}


static func start(spec: Dictionary, response: GdApiResponse) -> Dictionary:
	var runner = GdApiProcessRunner.create()
	var packed := PackedStringArray(spec.args)
	var id := int(runner.start(spec.executable, packed, spec.cwd, spec.timeout_ms, spec.max_output_bytes))
	if id < 0: return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "process could not start"}
	var state := {"runner": runner, "id": id, "response": response}
	return {"ok": true, "state": state}


static func tick(state: Dictionary, _now_ms: int) -> bool:
	var result: Dictionary = state.runner.poll(state.id)
	if not bool(result.get("done", false)): return false
	var payload := {"ok": true, "changed": true, "undoable": false, "exit_code": result.exit_code, "timed_out": result.timed_out, "cancelled": result.cancelled, "stdout": result.stdout, "stderr": result.stderr, "truncated": result.truncated}
	if result.timed_out: state.response.error("process timed out", ErrorCodes.TIMEOUT, 408)
	else: state.response.json(payload)
	return true


static func cancel(state: Dictionary, _reason: String) -> void:
	state.runner.cancel(state.id)
