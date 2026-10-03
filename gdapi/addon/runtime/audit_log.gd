@tool
class_name GdApiAuditLog
extends RefCounted

const MAX_STRING_LENGTH := 256
const MAX_DICTIONARY_KEYS := 16
const MAX_DICTIONARY_KEY_LENGTH := 64
const MAX_ARRAY_ITEMS := 32
const MAX_DEPTH := 8
const REDACTED := "[REDACTED]"

## 当前同步调用栈的请求上下文；异步完成必须显式传入 response 持有的上下文。
static var _context: Dictionary = {}


static func enter_request(context: Dictionary) -> Dictionary:
	var previous := _context
	_context = context
	return previous


static func safety_for_route(route: String) -> String:
	if (
		(
			route
			in [
				"editor/eval",
				"runtime/eval",
				"process/run",
				"network/http_request",
				"export/run",
				"gdapi/audit/clear",
				"scene/create",
				"scene/add_node",
				"scene/save",
				"scene/load_sprite",
				"scene/export_mesh_library",
				"uid/repair",
				"uid/update_all",
				"tilemap/layer/clear",
				"project/settings/set",
				"project/settings/reset",
			]
		)
		or route.begins_with("filesystem/batch/")
		or route.begins_with("project/autoload/")
		or route.begins_with("project/input_map/")
	):
		return "dangerous"
	if route.begins_with("runtime/"):
		return "runtime"
	if (
		(
			route
			in [
				"scene/open",
				"scene/close",
				"scene/current/save",
				"navigation/mesh/bake",
				"audio/bus/add",
				"audio/bus/remove",
				"material/save",
				"shader/write",
				"shader/param/set",
				"script/create",
				"script/write",
				"script/patch",
				"resource/create",
				"resource/move",
				"resource/delete",
				"resource/reimport",
			]
		)
		or route.begins_with("filesystem/")
		or route.begins_with("theme/")
	):
		return "file"
	return "mutation"


static func complete_request(context: Dictionary, body: Dictionary, status: int) -> void:
	if context.is_empty() or bool(context.get("completed", false)):
		return
	context["completed"] = true
	var ok := status < 400 and not body.has("error") and bool(body.get("ok", true))
	var event: Dictionary = context.get("event", {})
	if event.is_empty():
		if not bool(context.get("mutation", false)) and not body.has("changed"):
			return
		event = {
			"route": context["route"],
			"safety": safety_for_route(context["route"]),
			"summary": {"changed": bool(body.get("changed", false))},
		}
	event["ok"] = ok
	event["code"] = String(body.get("code", ""))
	_emit(event)


static func record(
	route: String,
	safety: String,
	summary: Dictionary,
	ok: bool,
	code: String = "",
	context: Dictionary = {}
) -> void:
	var owner := context if not context.is_empty() else _context
	var event := {
		"route": String(owner.get("route", route)),
		"safety": safety,
		"summary": summarize(summary),
		"ok": ok,
		"code": code,
	}
	if not owner.is_empty():
		if not bool(owner.get("completed", false)) and not owner.has("event"):
			owner["event"] = event
		return
	_emit(event)


static func _emit(event: Dictionary) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	if not plugin or not plugin.has_method("audit_event"):
		return
	plugin.audit_event(event)


static func record_runtime(
	route: String,
	payload: Variant,
	result: Variant,
	ok: bool,
	code: String = "",
	context: Dictionary = {}
) -> void:
	record(
		route,
		"dangerous" if route == "runtime/eval" else "runtime",
		{
			"operation": route,
			"payload": summarize(payload),
			"result": summarize(result),
		},
		ok,
		code,
		context
	)


## Return a bounded, recursively redacted audit representation.
static func summarize(value: Variant, depth: int = 0) -> Variant:
	if depth >= MAX_DEPTH:
		return _type_summary(value)
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary: Dictionary = value
		if dictionary.size() > MAX_DICTIONARY_KEYS:
			return _dictionary_summary(dictionary)
		var out: Dictionary = {}
		for key in dictionary:
			var key_text := String(key)
			var lowered := key_text.to_lower()
			var safe_key := _bounded_key(key_text)
			if _is_sensitive_key(lowered):
				out[safe_key] = REDACTED
				continue
			var child: Variant = dictionary[key]
			if lowered.ends_with("_base64") and typeof(child) == TYPE_STRING:
				out[safe_key] = {"type": "base64", "size": String(child).length()}
			else:
				out[safe_key] = summarize(child, depth + 1)
		return out
	if typeof(value) == TYPE_ARRAY:
		var array: Array = value
		if array.size() > MAX_ARRAY_ITEMS:
			return {"type": "array", "size": array.size()}
		var out_array: Array = []
		for child in array:
			out_array.append(summarize(child, depth + 1))
		return out_array
	if typeof(value) == TYPE_STRING:
		var text := String(value)
		if text.length() > MAX_STRING_LENGTH:
			return {"type": "string", "size": text.length()}
		return text
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		return {"type": "bytes", "size": value.size()}
	if typeof(value) == TYPE_BOOL or typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return value
	return _unclassified_summary(value)


static func _dictionary_summary(value: Dictionary) -> Dictionary:
	var keys: Array = []
	for key in value:
		keys.append(_bounded_key(String(key)))
		if keys.size() >= MAX_DICTIONARY_KEYS:
			break
	return {"type": "dictionary", "size": value.size(), "keys": keys}


static func _type_summary(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			return _dictionary_summary(value)
		TYPE_ARRAY:
			return {"type": "array", "size": value.size()}
		TYPE_STRING:
			return {"type": "string", "size": String(value).length()}
		TYPE_PACKED_BYTE_ARRAY:
			return {"type": "bytes", "size": value.size()}
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return value
		_:
			return _unclassified_summary(value)


static func _bounded_key(key: String) -> String:
	return key.left(MAX_DICTIONARY_KEY_LENGTH)


static func _unclassified_summary(value: Variant) -> Dictionary:
	var name := type_string(typeof(value))
	var summary := {"type": name}
	if name.begins_with("Packed"):
		summary["size"] = value.size()
	return summary


static func _is_sensitive_key(key: String) -> bool:
	var normalized := key.replace("-", "_").replace(".", "_")
	var compact := normalized.replace("_", "")
	var segments := normalized.split("_", false)
	if normalized == "auth" or segments.has("auth"):
		return true
	if (
		compact == "authheader"
		or compact.begins_with("authheader")
		or compact.ends_with("authheader")
	):
		return true
	for alias in [
		"source",
		"stdout",
		"stderr",
		"environment",
		"env",
		"headers",
		"header",
		"token",
		"password",
		"passwd",
		"secret",
		"authorization",
		"cookie",
		"api_key",
		"apikey",
		"private_key",
		"credential",
		"credentials",
		"passphrase",
		"bearer",
	]:
		if normalized == alias or normalized.contains(alias):
			return true
	return false
