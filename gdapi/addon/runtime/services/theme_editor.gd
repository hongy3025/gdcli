@tool
class_name GdApiThemeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")


static func create(path: Variant) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := Theme.new()
	return _save(theme, checked.path, "theme/create")


static func set_item(
	path: Variant, kind: String, type_name: Variant, item: Variant, value: Variant
) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := ResourceLoader.load(checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	if not theme is Theme:
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var decoded := VariantCodec.decode(value)
	if not decoded.ok:
		return _error(ErrorCodes.INVALID_PARAM, decoded.error)
	match kind:
		"color":
			if not decoded.value is Color:
				return _error(ErrorCodes.INVALID_PARAM, "value must be a Color")
			theme.set_color(String(item), String(type_name), decoded.value)
		"constant":
			var constant := _int_value(decoded.value)
			if not constant.ok:
				return _error(ErrorCodes.INVALID_PARAM, constant.error)
			theme.set_constant(String(item), String(type_name), constant.value)
		"font_size":
			var font_size := _int_value(decoded.value)
			if not font_size.ok:
				return _error(ErrorCodes.INVALID_PARAM, font_size.error)
			theme.set_font_size(String(item), String(type_name), font_size.value)
		_:
			return _error(ErrorCodes.INVALID_PARAM, "unsupported theme item kind")
	return _save(theme, checked.path, "theme/" + kind + "/set")


## JSON 数字一律解码为 float，因此整数值必须同时接受 4 与 4.0。
## 非整数、NaN/INF 拒绝；theme 常量不限制取值范围（允许负数）。
static func _int_value(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false, "error": "value must be an int, got " + type_string(typeof(value))}
	var number := float(value)
	if not is_finite(number):
		return {"ok": false, "error": "value must be a finite integer"}
	if number != floor(number):
		return {"ok": false, "error": "value must be an integer, got " + str(number)}
	return {"ok": true, "value": int(number)}


static func set_stylebox(
	path: Variant, type_name: Variant, item: Variant, value: Variant
) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := ResourceLoader.load(checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	if not theme is Theme:
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var decoded := VariantCodec.decode(value)
	if not decoded.ok or not decoded.value is StyleBox:
		return _error(ErrorCodes.INVALID_PARAM, "value must be a StyleBox")
	theme.set_stylebox(String(item), String(type_name), decoded.value)
	return _save(theme, checked.path, "theme/stylebox/set")


static func _save(resource: Resource, path: String, route: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		AuditLog.record(route, "file", {"path": path}, false, ErrorCodes.GODOT_ERROR)
		return _error(ErrorCodes.GODOT_ERROR, "failed to save theme")
	AuditLog.record(route, "file", {"path": path}, true)
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": path}


static func _path(path: Variant, mode: String) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "path must be a string")
	var checked := PathGuard.validate(path, mode)
	if not checked.ok:
		return _error(checked.code, checked.error)
	if (
		not String(checked.path).begins_with("res://")
		or not String(checked.path).ends_with(".tres")
	):
		return _error(ErrorCodes.INVALID_PATH, "theme path must be project-local .tres")
	return checked


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
