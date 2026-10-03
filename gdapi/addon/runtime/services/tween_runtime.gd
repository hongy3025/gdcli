@tool
class_name GdApiTweenRuntime
extends RefCounted

const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")
const MAX_RECORDS := 256
static var _records: Dictionary = {}
static var _next_id: int = 1


static func dispatch(op: String, payload: Dictionary) -> Dictionary:
	match op:
		"runtime/tween/start":
			return _start(payload)
		"runtime/tween/status":
			return _status(payload)
		"runtime/tween/stop":
			return _stop(payload)
	return _error("not_supported", "unknown tween operation")


# gdlint: ignore=max-returns
static func _start(payload: Dictionary) -> Dictionary:
	if (
		typeof(payload.get("node_path")) != TYPE_STRING
		or typeof(payload.get("property")) != TYPE_STRING
	):
		return _error("invalid_param", "node_path and property must be strings")
	var found: Dictionary = NodeOps._resolve(payload.node_path)
	if not found.ok:
		return found
	var node: Node = found.node
	var property: String = payload.property
	if not NodeOps._is_dedicated_target(node) or not NodeOps._is_mutable_property(property):
		return _error("permission_denied", "tween target/property is outside the runtime allowlist")
	if not NodeOps._has_property(node, property):
		return _error("not_found", "property does not exist")
	var duration: Variant = payload.get("duration")
	if not _number(duration) or float(duration) <= 0.0:
		return _error("invalid_param", "duration must be finite and positive")
	var ease: Variant = payload.get("ease", Tween.EASE_IN_OUT)
	var trans: Variant = payload.get("trans", Tween.TRANS_LINEAR)
	if not _integer(ease) or int(ease) < Tween.EASE_IN or int(ease) > Tween.EASE_OUT_IN:
		return _error("invalid_param", "ease must be a Tween.EaseType enum")
	if not _integer(trans) or int(trans) < Tween.TRANS_LINEAR or int(trans) > Tween.TRANS_SPRING:
		return _error("invalid_param", "trans must be a Tween.TransitionType enum")
	if not payload.has("to"):
		return _error("missing_param", "to is required")
	var current: Variant = node.get(property)
	if (
		typeof(current)
		not in [
			TYPE_INT,
			TYPE_FLOAT,
			TYPE_VECTOR2,
			TYPE_VECTOR3,
			TYPE_VECTOR4,
			TYPE_COLOR,
			TYPE_QUATERNION
		]
	):
		return _error("invalid_param", "property type cannot be interpolated")
	var to := Codec.decode(payload.to)
	var from := Codec.decode(payload.get("from", Codec.from_variant(current)))
	if not to.ok or not from.ok:
		return _error("invalid_param", "invalid VariantCodec from/to")
	if not _compatible(current, to.value) or not _compatible(current, from.value):
		return _error("invalid_param", "from/to must match the property type and be finite")
	for record in _records.values():
		if (
			record.state == "running"
			and record.target.get_ref() == node
			and record.property == property
		):
			return _error("conflict", "an active tween already owns this property")
	if _records.size() >= MAX_RECORDS:
		for old_id in _records.keys():
			if _records[old_id].state != "running":
				_records.erase(old_id)
				break
		if _records.size() >= MAX_RECORDS:
			return _error("conflict", "too many active tweens")
	var id := str(_next_id)
	_next_id += 1
	var tween: Tween = node.get_tree().create_tween().bind_node(node)
	(
		tween
		. tween_property(node, NodePath(property), to.value, float(duration))
		. from(from.value)
		. set_ease(int(ease))
		. set_trans(int(trans))
	)
	_records[id] = {
		"target": weakref(node),
		"tween": tween,
		"property": property,
		"node_path": str(node.get_path()),
		"state": "running",
		"duration": float(duration),
		"elapsed": 0.0,
		"value": Codec.from_variant(current)
	}
	_records[id]["exit_callback"] = _target_gone.bind(id)
	tween.finished.connect(_finish.bind(id))
	node.tree_exiting.connect(_records[id].exit_callback, CONNECT_ONE_SHOT)
	return _reply(id, true)


static func _status(payload: Dictionary) -> Dictionary:
	var id: Variant = payload.get("id")
	if typeof(id) != TYPE_STRING or not _records.has(id):
		return _error("not_found", "tween id not found")
	return _reply(id, false)


static func _stop(payload: Dictionary) -> Dictionary:
	var id: Variant = payload.get("id")
	if typeof(id) != TYPE_STRING or not _records.has(id):
		return _error("not_found", "tween id not found")
	var changed: bool = _records[id].state == "running"
	if changed:
		_end(id, "cancelled")
	return _reply(id, changed)


static func _finish(id: String) -> void:
	if _records.has(id) and _records[id].state == "running":
		_end(id, "completed")


static func _target_gone(id: String) -> void:
	if _records.has(id) and _records[id].state == "running":
		_end(id, "target_lost")


static func _end(id: String, state: String) -> void:
	var record: Dictionary = _records[id]
	var node: Node = record.target.get_ref()
	if is_instance_valid(node):
		record.value = Codec.from_variant(node.get(record.property))
		if node.tree_exiting.is_connected(record.exit_callback):
			node.tree_exiting.disconnect(record.exit_callback)
	record.elapsed = record.tween.get_total_elapsed_time()
	record.tween.kill()
	record.tween = null
	record.state = state


static func _reply(id: String, changed: bool) -> Dictionary:
	var record: Dictionary = _records[id]
	if record.state == "running":
		var node: Node = record.target.get_ref()
		if not is_instance_valid(node):
			_end(id, "target_lost")
		else:
			record.value = Codec.from_variant(node.get(record.property))
			record.elapsed = record.tween.get_total_elapsed_time()
	return {
		"ok": true,
		"result":
		{
			"id": id,
			"state": record.state,
			"node_path": record.node_path,
			"property": record.property,
			"value": record.value,
			"elapsed": record.elapsed,
			"duration": record.duration,
			"progress": minf(record.elapsed / record.duration, 1.0),
			"changed": changed,
			"undoable": false
		}
	}


static func _compatible(current: Variant, value: Variant) -> bool:
	if typeof(current) == TYPE_INT:
		return _integer(value)
	if typeof(current) in [TYPE_INT, TYPE_FLOAT]:
		return _number(value)
	if typeof(current) != typeof(value):
		return false
	if value is Quaternion:
		return (
			is_finite(value.x) and is_finite(value.y) and is_finite(value.z) and is_finite(value.w)
		)
	return value.is_finite()


static func _number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
