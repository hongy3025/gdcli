## 运行期 route 的统一 HTTP adapter。
##
## 该基类只负责 editor HTTP 请求与 RuntimeBroker 之间的协议适配；实际运行期
## operation 永远由 RuntimeProbe 在游戏进程执行。具体 route 通过继承本类保留
## 自己的 doc()，并在 handle() 中调用 dispatch()。

@tool
class_name GdApiRuntimeRoute
extends "res://addons/gdapi/runtime/route_handler.gd"

const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const DEFAULT_OPERATION_TIMEOUT := 5000
const MAX_OPERATION_TIMEOUT := 25000
const BROKER_GRACE_TIMEOUT := 1000
const MAX_BROKER_TIMEOUT := 26000


## 将 HTTP route 请求异步派发给运行期 broker。
##
## req.body 中的 timeout_ms 属于 operation 本身；broker deadline 额外保留固定
## grace，避免 operation 刚完成时 transport deadline 先到。
func dispatch(
	req: GdApiRequest,
	res: GdApiResponse,
	op: String,
	mutation: bool = false,
	public_route: String = "",
	version: int = Protocol.VERSION
) -> void:
	if res == null or res.is_sent():
		return
	var boundary := _validate_boundary(req, op, public_route)
	if not bool(boundary.get("ok", false)):
		_reject(req, res, op, mutation, boundary)
		return
	var timeout := operation_timeout(req)
	var payload_variant: Variant = req.body
	if not req.body_error.is_empty() or timeout < 0 or typeof(payload_variant) != TYPE_DICTIONARY:
		var invalid := {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "request body must be a JSON object"
		}
		_reject(req, res, op, mutation, invalid)
		return

	var payload: Dictionary = payload_variant.duplicate(true)
	payload["timeout_ms"] = timeout
	var protocol_verdict := Protocol.validate_message(
		Protocol.request_for_version(version, 1, op, payload)
	)
	if not bool(protocol_verdict.get("ok", false)):
		_reject(req, res, op, mutation, protocol_verdict)
		return
	var broker_timeout := mini(timeout + BROKER_GRACE_TIMEOUT, MAX_BROKER_TIMEOUT)
	var broker: Variant = RuntimeBroker.instance()
	if broker == null or not broker.has_method("request"):
		var disconnected := {
			"ok": false, "code": ErrorCodes.CONFLICT, "error": "runtime is not connected"
		}
		if mutation:
			_audit(op, payload, disconnected, false, ErrorCodes.CONFLICT)
		_send_error(res, disconnected)
		return
	var broker_status: Dictionary = broker.status() if broker.has_method("status") else {}
	if (
		version >= Protocol.VERSION_V2
		and (
			String(broker_status.get("state", "stopped")) != "connected"
			or int(broker_status.get("protocol_version", 0)) < version
		)
	):
		var unavailable := {
			"ok": false, "code": ErrorCodes.CONFLICT, "error": "runtime protocol is not negotiated"
		}
		if mutation:
			_audit(op, payload, unavailable, false, ErrorCodes.CONFLICT)
		_send_error(res, unavailable)
		return

	var completed := false
	var callback := func(reply: Dictionary) -> void:
		if completed or res.is_sent():
			return
		completed = true
		_complete(res, op, payload, mutation, reply)
	if version == Protocol.VERSION:
		broker.request(op, payload, broker_timeout, callback)
	else:
		broker.request(op, payload, broker_timeout, callback, version)


func dispatch_versioned(
	req: GdApiRequest,
	res: GdApiResponse,
	op: String,
	version: int,
	mutation: bool = false,
	public_route: String = ""
) -> void:
	dispatch(req, res, op, mutation, public_route, version)


## Return the validated operation timeout in milliseconds.
## A negative result is the invalid-param sentinel; a missing timeout uses the default.
static func operation_timeout(req: GdApiRequest) -> int:
	if req == null or typeof(req.body) != TYPE_DICTIONARY:
		return -1
	if not req.body.has("timeout_ms"):
		return DEFAULT_OPERATION_TIMEOUT
	var raw: Variant = req.body["timeout_ms"]
	var timeout_value: int = -1
	if typeof(raw) == TYPE_INT:
		if raw > 0:
			timeout_value = mini(int(raw), MAX_OPERATION_TIMEOUT)
	elif typeof(raw) == TYPE_FLOAT:
		var raw_float := float(raw)
		if (
			is_finite(raw_float)
			and raw_float == floor(raw_float)
			and raw_float > 0.0
			and raw_float <= float(MAX_OPERATION_TIMEOUT)
		):
			timeout_value = int(raw_float)
		elif (
			is_finite(raw_float)
			and raw_float == floor(raw_float)
			and raw_float > float(MAX_OPERATION_TIMEOUT)
		):
			timeout_value = MAX_OPERATION_TIMEOUT
	if timeout_value <= 0:
		return -1
	return timeout_value


## Return the stable HTTP status for a protocol error code.
static func http_status(code: String) -> int:
	return ErrorCodes.http_status(code)


## Recursively make values safe for audit summaries.
## Secrets are replaced; binary, base64, and large arrays are summarized by type/size.
static func redact(value: Variant) -> Variant:
	return AuditLog.summarize(value)


# gdlint: ignore=max-returns
func _validate_boundary(req: GdApiRequest, op: String, public_route: String = "") -> Dictionary:
	var error := ""
	if req == null:
		error = "request is required"
	elif op.is_empty() or op.contains("..") or op.contains("//"):
		error = "invalid internal operation"
	elif (
		public_route.is_empty()
		and (not op.begins_with("runtime/") or op.trim_prefix("runtime/").is_empty())
	):
		error = "invalid runtime operation"
	else:
		var expected_route := public_route if not public_route.is_empty() else op
		if (
			expected_route.is_empty()
			or expected_route.contains("..")
			or expected_route.contains("//")
		):
			error = "invalid public route"
		elif (
			req.path.is_empty() or not req.path.begins_with("/") or req.path != "/" + expected_route
		):
			error = "request path does not match public route"
		elif typeof(req.params) != TYPE_DICTIONARY:
			error = "request params must be an object"
		elif not req.params.is_empty():
			error = "runtime routes do not accept path params"
	if not error.is_empty():
		return _invalid_boundary(error)
	return {"ok": true}


func _invalid_boundary(error: String) -> Dictionary:
	return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": error}


func _complete(
	res: GdApiResponse, op: String, payload: Dictionary, mutation: bool, reply: Dictionary
) -> void:
	if res.is_sent():
		return
	if bool(reply.get("ok", false)):
		var result: Variant = reply.get("result", {})
		var body: Dictionary = {"ok": true}
		if typeof(result) == TYPE_DICTIONARY:
			for key in result:
				body[key] = result[key]
		else:
			body["result"] = result
		body["ok"] = true
		if mutation:
			body["changed"] = bool(body.get("changed", true))
			body["undoable"] = false
			body["operation"] = op
			_audit(op, payload, reply, true, "")
		res.json(body)
		return

	var code := String(reply.get("code", ErrorCodes.GODOT_ERROR))
	if code.is_empty():
		code = ErrorCodes.GODOT_ERROR
	if mutation:
		_audit(op, payload, reply, false, code)
	_send_error(res, reply)


func _send_error(res: GdApiResponse, failure: Dictionary) -> void:
	if res.is_sent():
		return
	var code := String(failure.get("code", ErrorCodes.GODOT_ERROR))
	var message := String(failure.get("error", "runtime operation failed"))
	var details: Dictionary = (
		failure.get("details", {}) if typeof(failure.get("details", {})) == TYPE_DICTIONARY else {}
	)
	res.error(message, code, http_status(code), details)


func _reject(
	req: GdApiRequest, res: GdApiResponse, op: String, mutation: bool, failure: Dictionary
) -> void:
	if mutation:
		var payload: Variant = req.body if req != null else null
		_audit(op, payload, failure, false, String(failure.get("code", ErrorCodes.INVALID_PARAM)))
	_send_error(res, failure)


func _audit(op: String, payload: Variant, result: Variant, ok: bool, code: String) -> void:
	AuditLog.record_runtime(op, payload, result, ok, code)
