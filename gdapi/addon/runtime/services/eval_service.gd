@tool
class_name GdApiEvalService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")

const MAX_SOURCE_BYTES := 16 * 1024
const ALLOWED_GLOBALS := ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color", "Rect2", "Rect2i", "Quaternion"]


static func execute(source: String, inputs: Dictionary, policy: Dictionary) -> Dictionary:
	if source.to_utf8_buffer().size() > min(MAX_SOURCE_BYTES, int(policy.get("max_source_bytes", MAX_SOURCE_BYTES))):
		return _error(ErrorCodes.INVALID_PARAM, "source exceeds policy limit")
	if inputs.size() > 64:
		return _error(ErrorCodes.INVALID_PARAM, "too many inputs")
	var allowed: Array = policy.get("allowed_input_keys", [])
	var names: Array[String] = []
	var values: Array = []
	for key in inputs:
		if typeof(key) != TYPE_STRING or not allowed.has(String(key)):
			return _error(ErrorCodes.PERMISSION_DENIED, "input key is not allowed")
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
	return {"ok": true, "value": VariantCodec.from_variant(value), "type": type_string(typeof(value)), "elapsed_ms": Time.get_ticks_msec() - started, "undoable": false}


static func _validate_source(source: String, names: Array[String]) -> Dictionary:
	if source.strip_edges().is_empty() or source.contains(";") or source.contains("\n") or source.contains("\r"):
		return _error(ErrorCodes.PERMISSION_DENIED, "statements are not permitted")
	for token in ["=", "load", "preload", "Engine", "OS", "ProjectSettings", "ClassDB", "get_tree", "while", "for", "func", "await", "yield", "Callable", "Object"]:
		if source.contains(token):
			return _error(ErrorCodes.PERMISSION_DENIED, "expression contains a forbidden token")
	if source.contains("."):
		return _error(ErrorCodes.PERMISSION_DENIED, "method and property access are not permitted")
	for global_name in ALLOWED_GLOBALS:
		if source.contains(global_name + "("):
			continue
	# Expression only receives explicitly named inputs; constructors are accepted by parser.
	for name in names:
		if name.contains("."):
			return _error(ErrorCodes.INVALID_PARAM, "invalid input name")
	return {"ok": true}


static func _contains_object(value: Variant) -> bool:
	if typeof(value) == TYPE_OBJECT or typeof(value) == TYPE_RID or typeof(value) == TYPE_CALLABLE:
		return true
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			if _contains_object(item):
				return true
	if typeof(value) == TYPE_DICTIONARY:
		for item in value.values():
			if _contains_object(item):
				return true
	return false


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
