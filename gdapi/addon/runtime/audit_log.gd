@tool
class_name GdApiAuditLog
extends RefCounted

const MAX_STRING_LENGTH := 256
const MAX_DICTIONARY_KEYS := 16
const MAX_DICTIONARY_KEY_LENGTH := 64
const MAX_ARRAY_ITEMS := 32
const MAX_DEPTH := 8
const REDACTED := "[REDACTED]"

static func record(route: String, safety: String, summary: Dictionary, ok: bool, code: String = "") -> void:
	if not Engine.has_meta("gdapi_plugin"):
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	if not plugin or not plugin.has_method("audit_event"):
		return
	var safe_summary: Variant = summarize(summary)
	plugin.audit_event({
		"route": route,
		"safety": safety,
		"summary": safe_summary if typeof(safe_summary) == TYPE_DICTIONARY else {
			"type": type_string(typeof(summary)),
		},
		"ok": ok,
		"code": code,
	})

static func record_runtime(route: String, payload: Variant, result: Variant, ok: bool, code: String = "") -> void:
	record(route, "runtime", {
		"operation": route,
		"payload": summarize(payload),
		"result": summarize(result),
	}, ok, code)

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
		TYPE_DICTIONARY: return _dictionary_summary(value)
		TYPE_ARRAY: return {"type": "array", "size": value.size()}
		TYPE_STRING: return {"type": "string", "size": String(value).length()}
		TYPE_PACKED_BYTE_ARRAY: return {"type": "bytes", "size": value.size()}
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT: return value
		_: return _unclassified_summary(value)

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
	if compact == "authheader" or compact.begins_with("authheader") or compact.ends_with("authheader"):
		return true
	for alias in [
		"token", "password", "passwd", "secret", "authorization", "cookie",
		"api_key", "apikey", "private_key", "credential", "credentials", "passphrase",
		"bearer",
	]:
		if normalized == alias or normalized.contains(alias):
			return true
	return false
