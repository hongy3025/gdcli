@tool
class_name GdApiEvalService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")

const MAX_SOURCE_BYTES := 16 * 1024
const ALLOWED_GLOBALS := [
	"Vector2",
	"Vector2i",
	"Vector3",
	"Vector3i",
	"Vector4",
	"Vector4i",
	"Color",
	"Rect2",
	"Rect2i",
	"Quaternion"
]


static func execute(source: String, inputs: Dictionary) -> Dictionary:
	if source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return _error(ErrorCodes.INVALID_PARAM, "source exceeds the 16 KiB limit")
	if inputs.size() > 64:
		return _error(ErrorCodes.INVALID_PARAM, "too many inputs")
	var names: Array[String] = []
	var values: Array = []
	for key in inputs:
		if typeof(key) != TYPE_STRING:
			return _error(ErrorCodes.INVALID_PARAM, "input names must be strings")
		var decoded := VariantCodec.decode(inputs[key])
		if not decoded.ok or _contains_object(decoded.value):
			return _error(ErrorCodes.INVALID_PARAM, "input value is not a permitted Variant")
		names.append(String(key))
		values.append(decoded.value)
	var scan := _validate_source(source, names)
	if not scan.ok:
		return scan
	var expression := Expression.new()
	var parse_error := expression.parse(source, names)
	if parse_error != OK:
		return _error(ErrorCodes.INVALID_PARAM, "expression could not be parsed")
	var started := Time.get_ticks_msec()
	var value: Variant = expression.execute(values, null, false)
	if expression.has_execute_failed():
		return _error(ErrorCodes.INVALID_PARAM, "expression execution failed")
	var result_verdict := _validate_result(value)
	if not result_verdict.ok:
		return result_verdict
	return {
		"ok": true,
		"value": VariantCodec.from_variant(value),
		"type": type_string(typeof(value)),
		"elapsed_ms": Time.get_ticks_msec() - started,
		"undoable": false
	}


static func _validate_source(source: String, names: Array[String]) -> Dictionary:
	if source.strip_edges().is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "source is required")
	var allowed_names := {
		"true": true, "false": true, "null": true, "and": true, "or": true, "not": true
	}
	for name in names:
		if not name.is_valid_identifier():
			return _error(ErrorCodes.INVALID_PARAM, "invalid input name")
		allowed_names[name] = true
	for name in ALLOWED_GLOBALS:
		allowed_names[name] = true
	var scan := _tokenize_identifiers(source)
	if not scan.ok:
		return scan
	for identifier in scan.identifiers:
		if not allowed_names.has(identifier):
			return _error(ErrorCodes.PERMISSION_DENIED, "identifier is not allowed")
		if scan.calls.has(identifier) and not ALLOWED_GLOBALS.has(identifier):
			return _error(ErrorCodes.PERMISSION_DENIED, "function is not allowed")
	return {"ok": true}


static func _tokenize_identifiers(source: String) -> Dictionary:
	var identifiers: Array[String] = []
	var calls: Dictionary = {}
	for forbidden in [".", ";", "\n", "\r", "[", "]", "{", "}", ":", "\\"]:
		if source.contains(forbidden):
			return _error(
				ErrorCodes.PERMISSION_DENIED, "statements and member access are not permitted"
			)
	var identifier_regex := RegEx.new()
	identifier_regex.compile("[A-Za-z_][A-Za-z0-9_]*")
	for match in identifier_regex.search_all(source):
		identifiers.append(match.get_string())
	var call_regex := RegEx.new()
	call_regex.compile("([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for match in call_regex.search_all(source):
		calls[match.get_string(1)] = true
	var assignment_regex := RegEx.new()
	assignment_regex.compile("(?<![<>=!])=(?!=)")
	if assignment_regex.search(source) != null:
		return _error(ErrorCodes.PERMISSION_DENIED, "assignment is not permitted")
	return {"ok": true, "identifiers": identifiers, "calls": calls}


static func _validate_result(value: Variant) -> Dictionary:
	if _contains_object(value):
		return _error(ErrorCodes.PERMISSION_DENIED, "expression result is not a permitted Variant")
	return {"ok": true}


static func _contains_object(value: Variant) -> bool:
	if (
		typeof(value) == TYPE_OBJECT
		or typeof(value) == TYPE_RID
		or typeof(value) == TYPE_CALLABLE
		or typeof(value) == TYPE_SIGNAL
	):
		return true
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			if _contains_object(item):
				return true
	if typeof(value) == TYPE_DICTIONARY:
		for key in value:
			if _contains_object(key) or _contains_object(value[key]):
				return true
	return false


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
