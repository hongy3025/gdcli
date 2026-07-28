## 运行期 route 的统一 HTTP adapter。
##
## 该基类只负责 editor HTTP 请求与 RuntimeBroker 之间的协议适配；实际运行期
## operation 永远由 RuntimeProbe 在游戏进程执行。具体 route 通过继承本类保留
## 自己的 doc()，并在 handle() 中调用 dispatch()。

@tool
class_name GdApiRuntimeRoute
extends "res://addons/gdapi/runtime/route_handler.gd"

const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const DEFAULT_OPERATION_TIMEOUT := 5000
const MAX_OPERATION_TIMEOUT := 25000
const BROKER_GRACE_TIMEOUT := 1000
const MAX_BROKER_TIMEOUT := 26000
const LARGE_ARRAY_THRESHOLD := 32
const REDACTED := "[REDACTED]"

## 将 HTTP route 请求异步派发给运行期 broker。
##
## req.body 中的 timeout_ms 属于 operation 本身；broker deadline 额外保留固定
## grace，避免 operation 刚完成时 transport deadline 先到。
func dispatch(req: GdApiRequest, res: GdApiResponse, op: String, mutation: bool = false) -> void:
	if res == null or res.is_sent():
		return
	var timeout := operation_timeout(req)
	var payload_variant: Variant = req.body if req != null else null
	if timeout < 0 or typeof(payload_variant) != TYPE_DICTIONARY:
		var invalid := {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "request body must be a JSON object"}
		if mutation:
			_audit(op, payload_variant, invalid, false, ErrorCodes.INVALID_PARAM)
		_send_error(res, invalid)
		return

	var payload: Dictionary = payload_variant.duplicate(true)
	if payload.has("timeout_ms"):
		payload["timeout_ms"] = timeout
	var broker_timeout := mini(timeout + BROKER_GRACE_TIMEOUT, MAX_BROKER_TIMEOUT)
	var broker: Variant = RuntimeBroker.instance()
	if broker == null or not broker.has_method("request"):
		var disconnected := {"ok": false, "code": ErrorCodes.CONFLICT, "error": "runtime is not connected"}
		if mutation:
			_audit(op, payload, disconnected, false, ErrorCodes.CONFLICT)
		_send_error(res, disconnected)
		return

	var completed := false
	broker.request(op, payload, broker_timeout, func(reply: Dictionary) -> void:
		if completed or res.is_sent():
			return
		completed = true
		_complete(res, op, payload, mutation, reply)
	)

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
		timeout_value = int(raw)
	elif typeof(raw) == TYPE_FLOAT and is_equal_approx(float(raw), round(float(raw))):
		timeout_value = int(raw)
	if timeout_value <= 0:
		return -1
	return mini(timeout_value, MAX_OPERATION_TIMEOUT)

## Return the stable HTTP status for a protocol error code.
static func http_status(code: String) -> int:
	return ErrorCodes.http_status(code)

## Recursively make values safe for audit summaries.
## Secrets are replaced; binary, base64, and large arrays are summarized by type/size.
static func redact(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var out: Dictionary = {}
		for key in value:
			var key_text := String(key)
			var lowered := key_text.to_lower()
			if lowered in ["token", "password", "secret", "authorization", "cookie"]:
				out[key] = REDACTED
				continue
			var child: Variant = value[key]
			if (lowered == "data_base64" or lowered.ends_with("_base64")) and typeof(child) == TYPE_STRING:
				out[key] = {"type": "base64", "size": String(child).length()}
			else:
				out[key] = redact(child)
		return out
	if typeof(value) == TYPE_ARRAY:
		var array: Array = value
		if array.size() > LARGE_ARRAY_THRESHOLD:
			return {"type": "array", "size": array.size()}
		var out_array: Array = []
		for child in array:
			out_array.append(redact(child))
		return out_array
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		return {"type": "bytes", "size": value.size()}
	return value

func _complete(res: GdApiResponse, op: String, payload: Dictionary, mutation: bool, reply: Dictionary) -> void:
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
	var details: Dictionary = failure.get("details", {}) if typeof(failure.get("details", {})) == TYPE_DICTIONARY else {}
	res.error(message, code, http_status(code), details)

func _audit(op: String, payload: Variant, result: Variant, ok: bool, code: String) -> void:
	AuditLog.record_runtime(op, redact(payload), redact(result), ok, code)
