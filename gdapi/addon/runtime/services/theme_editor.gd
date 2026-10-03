@tool
class_name GdApiThemeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const DATA_TYPES := {
	"color": Theme.DATA_TYPE_COLOR,
	"constant": Theme.DATA_TYPE_CONSTANT,
	"font": Theme.DATA_TYPE_FONT,
	"font_size": Theme.DATA_TYPE_FONT_SIZE,
	"icon": Theme.DATA_TYPE_ICON,
	"stylebox": Theme.DATA_TYPE_STYLEBOX,
}


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
	var names := _names(type_name, item)
	if not names.ok:
		return names
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
		"font":
			if not decoded.value is Font:
				return _error(ErrorCodes.INVALID_PARAM, "value must be a Font resource")
			theme.set_font(String(item), String(type_name), decoded.value)
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
	var names := _names(type_name, item)
	if not names.ok:
		return names
	var theme := ResourceLoader.load(checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	if not theme is Theme:
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var decoded := VariantCodec.decode(value)
	if not decoded.ok or not decoded.value is StyleBox:
		return _error(ErrorCodes.INVALID_PARAM, "value must be a StyleBox")
	theme.set_stylebox(String(item), String(type_name), decoded.value)
	return _save(theme, checked.path, "theme/stylebox/set")


static func _save(resource: Resource, path: String, route: String) -> Dictionary:
	return ResourceEditor.save_verified(resource, path, route)


## Resolve local items through type variations and native base classes, without
## pretending that a missing item is present just because Godot supplies a fallback.
static func get_item(path: Variant, kind: String, type_name: Variant, item: Variant) -> Dictionary:
	var names := _names(type_name, item)
	if not names.ok:
		return names
	if not DATA_TYPES.has(kind):
		return _error(ErrorCodes.INVALID_PARAM, "unsupported theme item kind")
	var target := _load_theme(path)
	if not target.ok:
		return target
	var theme: Theme = target.theme
	var data_type: int = DATA_TYPES[kind]
	var requested := String(type_name)
	var resolved := requested
	var visited: Array[String] = []
	var has := false
	while not resolved.is_empty() and resolved not in visited:
		visited.append(resolved)
		if String(item) in theme.get_theme_item_list(data_type, resolved):
			has = true
			break
		var base := String(theme.get_type_variation_base(resolved))
		if base.is_empty() and ClassDB.class_exists(resolved):
			base = String(ClassDB.get_parent_class(resolved))
		resolved = base
	var value: Variant = theme.get_theme_item(data_type, String(item), resolved) if has else null
	return {
		"ok": true,
		"path": target.path,
		"data_type": kind,
		"type": requested,
		"item": item,
		"has": has,
		"local_has": String(item) in theme.get_theme_item_list(data_type, requested),
		"inherited": has and resolved != requested,
		"resolved_type": resolved if has else "",
		"value": VariantCodec.from_variant(value),
		"undoable": false,
	}


static func items(path: Variant, kind: Variant = "", type_name: Variant = "") -> Dictionary:
	if typeof(kind) != TYPE_STRING or typeof(type_name) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "data_type and type must be strings")
	if not String(kind).is_empty() and not DATA_TYPES.has(kind):
		return _error(ErrorCodes.INVALID_PARAM, "unknown data_type")
	var target := _load_theme(path)
	if not target.ok:
		return target
	var theme: Theme = target.theme
	var types := theme.get_type_list()
	if not String(type_name).is_empty():
		types = PackedStringArray([String(type_name)])
	types.sort()
	var entries: Array = []
	for type in types:
		for data_kind in DATA_TYPES:
			if not String(kind).is_empty() and kind != data_kind:
				continue
			var names := theme.get_theme_item_list(DATA_TYPES[data_kind], type)
			names.sort()
			for name in names:
				(
					entries
					. append(
						{
							"data_type": data_kind,
							"type": type,
							"item": name,
							"value":
							VariantCodec.from_variant(
								theme.get_theme_item(DATA_TYPES[data_kind], name, type)
							),
							"has": true,
							"inherited": false,
						}
					)
				)
	return {"ok": true, "path": target.path, "items": entries, "types": types, "undoable": false}


static func _load_theme(path: Variant) -> Dictionary:
	var checked := _path(path, "read")
	if not checked.ok:
		return checked
	if not ResourceLoader.exists(checked.path):
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var resource := ResourceLoader.load(
		checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE_DEEP
	)
	if not resource is Theme:
		return _error(ErrorCodes.INVALID_PARAM, "resource is not a Theme")
	return {"ok": true, "path": checked.path, "theme": resource}


static func _names(type_name: Variant, item: Variant) -> Dictionary:
	if typeof(type_name) != TYPE_STRING or String(type_name).strip_edges().is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "type must be a non-empty string")
	if typeof(item) != TYPE_STRING or String(item).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "item must be a non-empty string")
	return {"ok": true}


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
