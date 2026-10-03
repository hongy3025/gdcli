@tool
class_name GdApiVariantCodec
extends RefCounted

const COMPOUND_COMPONENTS := {
	"Rect2": ["Vector2", "Vector2"],
	"Rect2i": ["Vector2i", "Vector2i"],
	"Transform2D": ["Vector2", "Vector2", "Vector2"],
	"Basis": ["Vector3", "Vector3", "Vector3"],
	"Transform3D": ["Basis", "Vector3"],
	"AABB": ["Vector3", "Vector3"],
}
const COMPONENT_TYPES := {
	"Vector2": TYPE_VECTOR2,
	"Vector2i": TYPE_VECTOR2I,
	"Vector3": TYPE_VECTOR3,
	"Basis": TYPE_BASIS,
}
const NUMERIC_COMPONENTS := {
	"Vector2": 2,
	"Vector2i": 2,
	"Vector3": 3,
	"Vector3i": 3,
	"Vector4": 4,
	"Vector4i": 4,
	"Color": 3,
	"Quaternion": 4,
}


## 带检查的类型解码，返回 {ok:true, value:Variant} 或 {ok:false, error:String}
static func decode(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {"ok": true, "value": value}
	if not value.has("type"):
		return {"ok": true, "value": value}
	if typeof(value.type) != TYPE_STRING:
		return {"ok": false, "error": "type must be a String"}
	var type_name: String = value.type
	var raw: Variant = value.get("value")
	if raw == null:
		return {"ok": false, "error": "missing value for type: " + type_name}
	if type_name in NUMERIC_COMPONENTS:
		var invalid := _numeric_error(raw, type_name)
		if not invalid.is_empty():
			return {"ok": false, "error": invalid}
	var decoded: Variant
	match type_name:
		"Vector2":
			decoded = Vector2(float(raw[0]), float(raw[1]))
		"Vector2i":
			decoded = Vector2i(int(raw[0]), int(raw[1]))
		"Vector3":
			decoded = Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
		"Vector3i":
			decoded = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
		"Vector4":
			decoded = Vector4(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"Vector4i":
			decoded = Vector4i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))
		"Color":
			decoded = Color(
				float(raw[0]),
				float(raw[1]),
				float(raw[2]),
				float(raw[3]) if raw.size() > 3 else 1.0
			)
		"Quaternion":
			decoded = Quaternion(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"Rect2", "Rect2i", "Transform2D", "Basis", "Transform3D", "AABB":
			decoded = _decode_compound(type_name, raw)
		"NodePath":
			decoded = NodePath(str(raw))
		"Resource":
			decoded = _decode_resource(raw)
		_:
			decoded = {"ok": false, "error": "unsupported Variant type: " + type_name}
	return decoded if typeof(decoded) == TYPE_DICTIONARY else {"ok": true, "value": decoded}


static func from_variant(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return {"type": "Vector2", "value": [value.x, value.y]}
		TYPE_VECTOR2I:
			return {"type": "Vector2i", "value": [value.x, value.y]}
		TYPE_VECTOR3:
			return {"type": "Vector3", "value": [value.x, value.y, value.z]}
		TYPE_VECTOR3I:
			return {"type": "Vector3i", "value": [value.x, value.y, value.z]}
		TYPE_VECTOR4:
			return {"type": "Vector4", "value": [value.x, value.y, value.z, value.w]}
		TYPE_VECTOR4I:
			return {"type": "Vector4i", "value": [value.x, value.y, value.z, value.w]}
		TYPE_COLOR:
			return {"type": "Color", "value": [value.r, value.g, value.b, value.a]}
		TYPE_RECT2:
			return {
				"type": "Rect2",
				"value": [from_variant(value.position).value, from_variant(value.size).value]
			}
		TYPE_RECT2I:
			return {
				"type": "Rect2i",
				"value": [from_variant(value.position).value, from_variant(value.size).value]
			}
		TYPE_QUATERNION:
			return {"type": "Quaternion", "value": [value.x, value.y, value.z, value.w]}
		TYPE_TRANSFORM2D:
			return {
				"type": "Transform2D",
				"value":
				[
					from_variant(value.x).value,
					from_variant(value.y).value,
					from_variant(value.origin).value,
				]
			}
		TYPE_BASIS:
			return {
				"type": "Basis",
				"value":
				[
					from_variant(value.x).value,
					from_variant(value.y).value,
					from_variant(value.z).value,
				]
			}
		TYPE_TRANSFORM3D:
			return {
				"type": "Transform3D",
				"value":
				[
					from_variant(value.basis).value,
					from_variant(value.origin).value,
				]
			}
		TYPE_AABB:
			return {
				"type": "AABB",
				"value":
				[
					from_variant(value.position).value,
					from_variant(value.size).value,
				]
			}
		TYPE_NODE_PATH:
			return {"type": "NodePath", "value": str(value)}
		TYPE_OBJECT:
			if value is Resource and value.resource_path != "":
				return {"type": "Resource", "value": value.resource_path}
			return str(value)
		_:
			return value


## from_variant() 输出紧凑数组，同时接受调用方显式 typed 的嵌套分量。
static func _decode_compound(type_name: String, raw: Variant) -> Dictionary:
	var names: Array = COMPOUND_COMPONENTS[type_name]
	if not _check_size(raw, names.size()):
		return {"ok": false, "error": "%s requires %d components" % [type_name, names.size()]}
	var components: Array = []
	for index in names.size():
		var part := _decode_component(raw[index], String(names[index]))
		if not part.ok:
			return {"ok": false, "error": "%s component %d: %s" % [type_name, index, part.error]}
		components.append(part.value)
	var result: Variant
	match type_name:
		"Rect2":
			result = Rect2(components[0], components[1])
		"Rect2i":
			result = Rect2i(components[0], components[1])
		"Transform2D":
			result = Transform2D(components[0], components[1], components[2])
		"Basis":
			result = Basis(components[0], components[1], components[2])
		"Transform3D":
			result = Transform3D(components[0], components[1])
		"AABB":
			result = AABB(components[0], components[1])
	return {"ok": true, "value": result}


static func _decode_component(raw: Variant, type_name: String) -> Dictionary:
	var expected: int = COMPONENT_TYPES[type_name]
	if typeof(raw) == expected:
		return {"ok": true, "value": raw}
	var wrapped: Dictionary
	if typeof(raw) == TYPE_DICTIONARY:
		if raw.get("type") != type_name:
			return {"ok": false, "error": "expected " + type_name}
		wrapped = raw
	else:
		wrapped = {"type": type_name, "value": raw}
	var decoded := decode(wrapped)
	if not decoded.ok:
		return decoded
	if typeof(decoded.value) != expected:
		return {"ok": false, "error": "expected " + type_name}
	return decoded


static func _numeric_error(raw: Variant, type_name: String) -> String:
	var count: int = NUMERIC_COMPONENTS[type_name]
	if not _check_size(raw, count):
		return "%s requires %d numbers" % [type_name, count]
	if type_name == "Color" and raw.size() > 3:
		count = 4
	for index in count:
		if typeof(raw[index]) != TYPE_INT and typeof(raw[index]) != TYPE_FLOAT:
			return type_name + " components must be numbers"
		var number := float(raw[index])
		if not is_finite(number):
			return type_name + " components must be finite"
		if (
			type_name.ends_with("i")
			and (number != floor(number) or number < -2147483648.0 or number > 2147483647.0)
		):
			return type_name + " components must be 32-bit integers"
	return ""


static func _decode_resource(raw: Variant) -> Dictionary:
	var resource_path := str(raw)
	if resource_path.is_empty():
		return {"ok": false, "error": "Resource path is empty"}
	if not resource_path.begins_with("res://") and not resource_path.begins_with("user://"):
		return {"ok": false, "error": "Resource path must be res:// or user://"}
	var resource: Resource = load(resource_path)
	if resource == null:
		return {"ok": false, "error": "Resource not found: " + resource_path}
	return {"ok": true, "value": resource}


static func _check_size(raw: Variant, min_size: int) -> bool:
	return typeof(raw) >= TYPE_ARRAY and raw.size() >= min_size
