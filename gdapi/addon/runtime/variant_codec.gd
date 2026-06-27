@tool
class_name GdApiVariantCodec
extends RefCounted

static func to_variant(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return value
	if not value.has("type"):
		return value
	var type_name: String = value.get("type", "")
	var raw = value.get("value", null)
	if raw == null:
		return value
	match type_name:
		"Vector2":
			if not _check_size(raw, 2): return value
			return Vector2(float(raw[0]), float(raw[1]))
		"Vector2i":
			if not _check_size(raw, 2): return value
			return Vector2i(int(raw[0]), int(raw[1]))
		"Vector3":
			if not _check_size(raw, 3): return value
			return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
		"Vector3i":
			if not _check_size(raw, 3): return value
			return Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
		"Vector4":
			if not _check_size(raw, 4): return value
			return Vector4(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"Vector4i":
			if not _check_size(raw, 4): return value
			return Vector4i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))
		"Color":
			if not _check_size(raw, 3): return value
			return Color(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]) if raw.size() > 3 else 1.0)
		"Rect2":
			if not _check_size(raw, 2): return value
			return Rect2(to_variant({"type":"Vector2","value":raw[0]}), to_variant({"type":"Vector2","value":raw[1]}))
		"Rect2i":
			if not _check_size(raw, 2): return value
			return Rect2i(to_variant({"type":"Vector2i","value":raw[0]}), to_variant({"type":"Vector2i","value":raw[1]}))
		"Quaternion":
			if not _check_size(raw, 4): return value
			return Quaternion(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"Transform2D":
			if not _check_size(raw, 3): return value
			return Transform2D(
				to_variant({"type":"Vector2","value":raw[0]}),
				to_variant({"type":"Vector2","value":raw[1]}),
				to_variant({"type":"Vector2","value":raw[2]})
			)
		"Basis":
			if not _check_size(raw, 3): return value
			return Basis(
				to_variant({"type":"Vector3","value":raw[0]}),
				to_variant({"type":"Vector3","value":raw[1]}),
				to_variant({"type":"Vector3","value":raw[2]})
			)
		"Transform3D":
			if not _check_size(raw, 2): return value
			return Transform3D(
				to_variant({"type":"Basis","value":raw[0]}),
				to_variant({"type":"Vector3","value":raw[1]})
			)
		"AABB":
			if not _check_size(raw, 2): return value
			return AABB(
				to_variant({"type":"Vector3","value":raw[0]}),
				to_variant({"type":"Vector3","value":raw[1]})
			)
		"NodePath": return NodePath(str(raw))
		"Resource": return load(str(raw))
		_: return value

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
