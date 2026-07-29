@tool
class_name GdApiClassDbQuery
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const MAX_LIMIT := 500


static func classes(body: Dictionary) -> Dictionary:
	var filter := String(body.get("filter", ""))
	var names: Array = []
	for name in ClassDB.get_class_list():
		if filter.is_empty() or String(name).contains(filter):
			names.append(String(name))
	names.sort()
	return {"ok": true, "items": _page(names, body)}


static func class_detail(name: String) -> Dictionary:
	if not ClassDB.class_exists(name):
		return _err(ErrorCodes.NOT_FOUND, "class not found: " + name)
	var enum_names: Array = []
	for item in ClassDB.class_get_integer_constant_list(name):
		enum_names.append(String(item))
	enum_names.sort()
	return {
		"ok": true,
		"name": name,
		"parent": ClassDB.get_parent_class(name),
		"instantiable": ClassDB.can_instantiate(name),
		"exposed": true,
		"enum_names": enum_names
	}


static func members(name: String, kind: String, body: Dictionary) -> Dictionary:
	if not ClassDB.class_exists(name):
		return _err(ErrorCodes.NOT_FOUND, "class not found: " + name)
	var inherited := bool(body.get("inherited", true))
	var source: Array = []
	match kind:
		"methods":
			source = ClassDB.class_get_method_list(name, not inherited)
		"properties":
			source = ClassDB.class_get_property_list(name, not inherited)
		"signals":
			source = ClassDB.class_get_signal_list(name, not inherited)
	var filter := String(body.get("filter", ""))
	var items: Array = []
	for raw in source:
		var item := _normalize(raw, kind)
		if filter.is_empty() or String(item.get("name", "")).contains(filter):
			items.append(item)
	items.sort_custom(func(a, b): return String(a.get("name", "")) < String(b.get("name", "")))
	return {"ok": true, "class": name, "items": _page(items, body)}


static func inheriters(name: String, body: Dictionary) -> Dictionary:
	if not ClassDB.class_exists(name):
		return _err(ErrorCodes.NOT_FOUND, "class not found: " + name)
	var items: Array = []
	for candidate in ClassDB.get_class_list():
		var child := String(candidate)
		if child != name and ClassDB.is_parent_class(child, name):
			items.append(child)
	items.sort()
	return {"ok": true, "class": name, "items": _page(items, body)}


static func _normalize(raw: Dictionary, kind: String) -> Dictionary:
	var item: Dictionary = {"name": String(raw.get("name", ""))}
	if kind == "methods":
		item["return_type"] = _type_name(raw.get("return", {}))
		item["flags"] = int(raw.get("flags", 0))
		item["arguments"] = []
		for argument in raw.get("args", []):
			item["arguments"].append(
				{
					"name": String(argument.get("name", "")),
					"type": _type_name(argument),
					"default": argument.get("default_value", null)
				}
			)
	elif kind == "properties":
		item["type"] = _type_name(raw)
		item["usage"] = int(raw.get("usage", 0))
		item["class_name"] = String(raw.get("class_name", ""))
	elif kind == "signals":
		item["arguments"] = []
		for argument in raw.get("args", []):
			item["arguments"].append(
				{"name": String(argument.get("name", "")), "type": _type_name(argument)}
			)
	return item


static func _type_name(value: Variant) -> String:
	if typeof(value) == TYPE_DICTIONARY:
		var type_id := int(value.get("type", TYPE_NIL))
		return (
			String(value.get("class_name", ""))
			if not String(value.get("class_name", "")).is_empty()
			else type_string(type_id)
		)
	return type_string(int(value))


static func _page(values: Array, body: Dictionary) -> Array:
	var offset := maxi(0, int(body.get("offset", 0)))
	var limit := clampi(int(body.get("limit", 100)), 1, MAX_LIMIT)
	return values.slice(offset, mini(values.size(), offset + limit))


static func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
