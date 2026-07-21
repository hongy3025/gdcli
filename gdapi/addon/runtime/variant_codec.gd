@tool
class_name GdApiVariantCodec
extends RefCounted

## 带检查的类型解码，返回 {ok:true, value:Variant} 或 {ok:false, error:String}
static func decode(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {"ok": true, "value": value}
	if not value.has("type"):
		return {"ok": true, "value": value}
	var type_name: String = value.get("type", "")
	var raw = value.get("value", null)
	if raw == null:
		return {"ok": false, "error": "missing value for type: " + type_name}
	match type_name:
		"Vector2":
			if not _check_size(raw, 2): return {"ok": false, "error": "Vector2 requires 2 values"}
			return {"ok": true, "value": Vector2(float(raw[0]), float(raw[1]))}
		"Vector2i":
			if not _check_size(raw, 2): return {"ok": false, "error": "Vector2i requires 2 values"}
			return {"ok": true, "value": Vector2i(int(raw[0]), int(raw[1]))}
		"Vector3":
			if not _check_size(raw, 3): return {"ok": false, "error": "Vector3 requires 3 values"}
			return {"ok": true, "value": Vector3(float(raw[0]), float(raw[1]), float(raw[2]))}
		"Vector3i":
			if not _check_size(raw, 3): return {"ok": false, "error": "Vector3i requires 3 values"}
			return {"ok": true, "value": Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))}
		"Vector4":
			if not _check_size(raw, 4): return {"ok": false, "error": "Vector4 requires 4 values"}
			return {"ok": true, "value": Vector4(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))}
		"Vector4i":
			if not _check_size(raw, 4): return {"ok": false, "error": "Vector4i requires 4 values"}
			return {"ok": true, "value": Vector4i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))}
		"Color":
			if not _check_size(raw, 3): return {"ok": false, "error": "Color requires at least 3 values"}
			return {"ok": true, "value": Color(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]) if raw.size() > 3 else 1.0)}
		"Rect2":
			if not _check_size(raw, 2): return {"ok": false, "error": "Rect2 requires 2 values"}
			return {"ok": true, "value": Rect2(decode(raw[0]).value, decode(raw[1]).value)}
		"Rect2i":
			if not _check_size(raw, 2): return {"ok": false, "error": "Rect2i requires 2 values"}
			return {"ok": true, "value": Rect2i(decode(raw[0]).value, decode(raw[1]).value)}
		"Quaternion":
			if not _check_size(raw, 4): return {"ok": false, "error": "Quaternion requires 4 values"}
			return {"ok": true, "value": Quaternion(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))}
		"Transform2D":
			if not _check_size(raw, 3): return {"ok": false, "error": "Transform2D requires 3 values"}
			if not (_check_size(raw[0], 2) and _check_size(raw[1], 2) and _check_size(raw[2], 2)):
				return {"ok": false, "error": "Transform2D vectors require 2 values"}
			return {"ok": true, "value": Transform2D(Vector2(float(raw[0][0]), float(raw[0][1])), Vector2(float(raw[1][0]), float(raw[1][1])), Vector2(float(raw[2][0]), float(raw[2][1])))}
		"Basis":
			if not _check_size(raw, 3): return {"ok": false, "error": "Basis requires 3 values"}
			return {"ok": true, "value": Basis(decode(raw[0]).value, decode(raw[1]).value, decode(raw[2]).value)}
		"Transform3D":
			if not _check_size(raw, 2): return {"ok": false, "error": "Transform3D requires 2 values"}
			return {"ok": true, "value": Transform3D(decode(raw[0]).value, decode(raw[1]).value)}
		"AABB":
			if not _check_size(raw, 2): return {"ok": false, "error": "AABB requires 2 values"}
			return {"ok": true, "value": AABB(decode(raw[0]).value, decode(raw[1]).value)}
		"NodePath":
			return {"ok": true, "value": NodePath(str(raw))}
		"Resource":
			var resource_path: String = str(raw)
			if resource_path.is_empty():
				return {"ok": false, "error": "Resource path is empty"}
			if not resource_path.begins_with("res://") and not resource_path.begins_with("user://"):
				return {"ok": false, "error": "Resource path must be res:// or user://"}
			var res_load = load(resource_path)
			if res_load == null:
				return {"ok": false, "error": "Resource not found: " + resource_path}
			return {"ok": true, "value": res_load}
		_:
			return {"ok": false, "error": "unsupported Variant type: " + type_name}

## 兼容性包装器，调用 decode() 并返回原始值，失败时返回原值
static func to_variant(value: Variant) -> Variant:
	var result := decode(value)
	return result.value if result.ok else value

static func from_variant(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {"type":"Vector2", "value":[value.x, value.y]}
		TYPE_VECTOR2I: return {"type":"Vector2i", "value":[value.x, value.y]}
		TYPE_VECTOR3: return {"type":"Vector3", "value":[value.x, value.y, value.z]}
		TYPE_VECTOR3I: return {"type":"Vector3i", "value":[value.x, value.y, value.z]}
		TYPE_VECTOR4: return {"type":"Vector4", "value":[value.x, value.y, value.z, value.w]}
		TYPE_VECTOR4I: return {"type":"Vector4i", "value":[value.x, value.y, value.z, value.w]}
		TYPE_COLOR: return {"type":"Color", "value":[value.r, value.g, value.b, value.a]}
		TYPE_RECT2: return {"type":"Rect2", "value":[from_variant(value.position).value, from_variant(value.size).value]}
		TYPE_RECT2I: return {"type":"Rect2i", "value":[from_variant(value.position).value, from_variant(value.size).value]}
		TYPE_QUATERNION: return {"type":"Quaternion", "value":[value.x, value.y, value.z, value.w]}
		TYPE_TRANSFORM2D:
			return {"type":"Transform2D", "value":[
				from_variant(value.x).value,
				from_variant(value.y).value,
				from_variant(value.origin).value,
			]}
		TYPE_BASIS:
			return {"type":"Basis", "value":[
				from_variant(value.x).value,
				from_variant(value.y).value,
				from_variant(value.z).value,
			]}
		TYPE_TRANSFORM3D:
			return {"type":"Transform3D", "value":[
				from_variant(value.basis).value,
				from_variant(value.origin).value,
			]}
		TYPE_AABB:
			return {"type":"AABB", "value":[
				from_variant(value.position).value,
				from_variant(value.size).value,
			]}
		TYPE_NODE_PATH: return {"type":"NodePath", "value":str(value)}
		TYPE_OBJECT:
			if value is Resource and value.resource_path != "":
				return {"type":"Resource", "value":value.resource_path}
			return str(value)
		_: return value

static func _check_size(raw: Variant, min_size: int) -> bool:
	return typeof(raw) >= TYPE_ARRAY and raw.size() >= min_size
