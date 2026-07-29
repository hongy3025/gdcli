## 运行时 node 操作实现
##
## 在游戏进程内执行 scene/tree、node/info|get|set|call|find|remove|reparent
## 以及 assert/signal 系列操作。所有方法都是纯静态,返回 {"ok":..., "result"/"error":...}。
##
## 方法列表:
## - tree(payload)
## - info(payload)
## - get_property(payload)
## - set_property(payload)
## - call_method(payload)
## - find(payload)
## - remove(payload)
## - reparent(payload)
## - assert_condition(payload)
## - assert_node_exists(payload)
## - assert_property_equals(payload)
## - assert_signal_received(payload)
## - signal_connect(payload)
## - signal_disconnect(payload)
## - signal_emit(payload)
## - signal_await(payload)

@tool
class_name GdApiRuntimeNodeOps
extends RefCounted

const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const Condition := preload("res://addons/gdapi/runtime/runtime_condition.gd")
const ALLOWED_CREATE_TYPES := ["Node", "Node2D", "Control", "Marker2D"]
const DEDICATED_NODE_META := &"gdapi_runtime_dedicated"
const DEDICATED_FIXTURE_NODE_NAMES := ["ProbeTarget"]
const INFRASTRUCTURE_NODE_NAMES := ["ProbeInput", "ProbeInputAction", "ProbeFinishedSignal"]
const MUTABLE_PROPERTIES := [
	"position", "rotation", "rotation_degrees", "scale", "skew", "pivot_offset",
	"size", "visible", "modulate", "self_modulate", "process_mode",
	"counter", "spawn_position", "input_keys", "input_mouse", "input_gamepad",
	"input_touch", "input_actions",
]

## 返回 root 节点的子节点树。最大深度由 payload.max_depth 控制(默认 16,最大 32)。
static func tree(payload: Dictionary) -> Dictionary:
	var max_depth: int = clampi(int(payload.get("max_depth", 16)), 1, 32)
	var root: Node = _scene_root()
	if root == null:
		return {"ok": false, "code": "not_found", "error": "scene root is unavailable"}
	var out: Dictionary = _serialize_node(root, 0, max_depth, [])
	return {"ok": true, "result": {"root": out}}

## 实现 runtime/node/info
## 返回节点类型、所在路径、属性列表摘要。
static func info(payload: Dictionary) -> Dictionary:
	var node_path: String = String(payload.get("node_path", ""))
	var lookup: Dictionary = _resolve(node_path)
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var result: Dictionary = {
		"node_path": String(lookup.node_path),
		"type": node.get_class(),
		"script": (node.get_script().resource_path if node.get_script() != null else ""),
		"properties": _public_properties(node),
	}
	return {"ok": true, "result": result}

## 实现 runtime/node/get
static func get_property(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var property: String = String(payload.get("property", ""))
	if property.is_empty():
		return {"ok": false, "code": "missing_param", "error": "property is required"}
	if not _has_property(node, property):
		return {"ok": false, "code": "not_found", "error": "property does not exist: %s" % property}
	var raw: Variant = node.get(property)
	var encoded: Variant = Codec.from_variant(raw) if raw != null else {"plain": null}
	return {"ok": true, "result": {"value": encoded}}

## 实现 runtime/node/set
static func set_property(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	if not _is_dedicated_target(node):
		return {"ok": false, "code": "permission_denied", "error": "node is not a dedicated runtime target"}
	var property: String = String(payload.get("property", ""))
	var value: Variant = payload.get("value", null)
	if property.is_empty() or value == null:
		return {"ok": false, "code": "missing_param", "error": "property and value are required"}
	if not _has_property(node, property):
		return {"ok": false, "code": "not_found", "error": "property does not exist: %s" % property}
	if not _is_mutable_property(property):
		return {"ok": false, "code": "permission_denied", "error": "property is not in the runtime allowlist: %s" % property}
	var decoded: Dictionary = Codec.decode(value)
	if not bool(decoded.get("ok", false)):
		return {"ok": false, "code": "invalid_param", "error": String(decoded.get("error", "invalid VariantCodec value"))}
	node.set(property, decoded.value)
	return {"ok": true, "result": {"undoable": false, "changed": true, "property": property}}

## 实现 runtime/node/call
static func call_method(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	if not _is_dedicated_target(node):
		return {"ok": false, "code": "permission_denied", "error": "node is not a dedicated runtime target"}
	var method: String = String(payload.get("method", ""))
	if method.is_empty():
		return {"ok": false, "code": "missing_param", "error": "method is required"}
	var allowlist_meta: Variant = node.get_meta("gdapi_callable_methods", PackedStringArray())
	if not (allowlist_meta is PackedStringArray):
		return {"ok": false, "code": "permission_denied", "error": "node does not declare an allowlist"}
	var allowlist: PackedStringArray = allowlist_meta
	if not (method in allowlist):
		return {"ok": false, "code": "permission_denied", "error": "method is not in allowlist: %s" % method}
	var args: Variant = payload.get("args", [])
	if typeof(args) != TYPE_ARRAY:
		return {"ok": false, "code": "invalid_param", "error": "args must be an array"}
	var decoded_args: Array = []
	for encoded in args:
		var decoded_arg := Codec.decode(encoded)
		if not bool(decoded_arg.get("ok", false)):
			return {"ok": false, "code": "invalid_param", "error": String(decoded_arg.get("error", "invalid VariantCodec argument"))}
		decoded_args.append(decoded_arg.value)
	var result: Variant = node.callv(method, decoded_args)
	var encoded: Variant = Codec.from_variant(result) if result != null else {"plain": null}
	return {"ok": true, "result": {"result": encoded, "method": method}}

## 实现 runtime/node/find
static func find(payload: Dictionary) -> Dictionary:
	var limit: int = clampi(int(payload.get("limit", 32)), 1, 200)
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	var name: String = String(payload.get("name", ""))
	var type_filter: String = String(payload.get("type", ""))
	var group: String = String(payload.get("group", ""))
	var found: Array = []
	_walk_find(root, name, type_filter, group, found, limit)
	return {"ok": true, "result": {"nodes": found, "total": found.size()}}

## 实现 runtime/node/remove
static func remove(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	if _is_protected_node(node):
		return {"ok": false, "code": "permission_denied", "error": "cannot remove protected runtime node"}
	if not _is_dedicated_target(node):
		return {"ok": false, "code": "permission_denied", "error": "node is outside the current scene"}
	if node.get_parent() == null:
		return {"ok": false, "code": "permission_denied", "error": "cannot remove orphan node"}
	var path_str: String = String(node.get_path())
	node.queue_free()
	return {"ok": true, "result": {"removed": path_str, "undoable": false}}

## 实现 runtime/node/reparent
static func reparent(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var parent_path: String = String(payload.get("new_parent", ""))
	var parent_lookup: Dictionary = _resolve(parent_path)
	if not bool(parent_lookup.get("ok", false)):
		return parent_lookup
	var new_parent: Node = parent_lookup.node
	if _is_protected_node(node) or not _is_dedicated_target(node):
		return {"ok": false, "code": "permission_denied", "error": "node is not a reparentable fixture node"}
	if new_parent != _scene_root() and not _is_dedicated_target(new_parent):
		return {"ok": false, "code": "permission_denied", "error": "new parent is not a dedicated runtime target"}
	if node == new_parent or _is_descendant_of(new_parent, node, false):
		return {"ok": false, "code": "conflict", "error": "reparent would create a cycle"}
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	return {"ok": true, "result": {"new_parent": String(new_parent.get_path()), "undoable": false}}

## 创建运行期 allowlisted 节点。
static func create(payload: Dictionary) -> Dictionary:
	var parent_lookup := _resolve(String(payload.get("parent_path", "")))
	if not bool(parent_lookup.get("ok", false)):
		return parent_lookup
	var parent: Node = parent_lookup.node
	if parent != _scene_root():
		return {"ok": false, "code": "permission_denied", "error": "create parent must be the current scene root"}
	var name_result := _validate_node_name(String(payload.get("name", "")))
	if not bool(name_result.get("ok", false)):
		return name_result
	var node_name := String(name_result.name)
	if parent.has_node(NodePath(node_name)):
		return {"ok": false, "code": "conflict", "error": "node name already exists: %s" % node_name}
	var type_name := String(payload.get("type", ""))
	if type_name not in ALLOWED_CREATE_TYPES:
		return {"ok": false, "code": "permission_denied", "error": "node type is not in the runtime allowlist: %s" % type_name}
	var candidate := ClassDB.instantiate(type_name) as Node
	if candidate == null:
		return {"ok": false, "code": "invalid_param", "error": "node type cannot be instantiated: %s" % type_name}
	var properties: Variant = payload.get("properties", {})
	if typeof(properties) != TYPE_DICTIONARY:
		candidate.free()
		return {"ok": false, "code": "invalid_param", "error": "properties must be an object"}
	for property_key in properties:
		var property := String(property_key)
		if not _is_mutable_property(property) or not _has_property(candidate, property):
			candidate.free()
			return {"ok": false, "code": "permission_denied", "error": "property is not allowed for create: %s" % property}
		var decoded := Codec.decode(properties[property_key])
		if not bool(decoded.get("ok", false)):
			candidate.free()
			return {"ok": false, "code": "invalid_param", "error": String(decoded.get("error", "invalid VariantCodec property"))}
		candidate.set(property, decoded.value)
	candidate.name = node_name
	_mark_dedicated_node(candidate)
	parent.add_child(candidate)
	return {"ok": true, "result": {"node_path": String(candidate.get_path()), "type": type_name, "changed": true, "undoable": false}}

## 复制当前场景中的专用节点，保留 Godot duplicate() 复制的 typed properties。
static func duplicate_node(payload: Dictionary) -> Dictionary:
	var lookup := _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var source: Node = lookup.node
	if _is_protected_node(source):
		return {"ok": false, "code": "permission_denied", "error": "cannot duplicate protected runtime node"}
	if not _is_dedicated_target(source):
		return {"ok": false, "code": "permission_denied", "error": "only dedicated scene nodes may be duplicated"}
	var parent := source.get_parent()
	if parent == null:
		return {"ok": false, "code": "permission_denied", "error": "source node has no parent"}
	var name_result := _validate_node_name(String(payload.get("name", "")))
	if not bool(name_result.get("ok", false)):
		return name_result
	var node_name := String(name_result.name)
	if parent.has_node(NodePath(node_name)):
		return {"ok": false, "code": "conflict", "error": "node name already exists: %s" % node_name}
	var copy := ClassDB.instantiate(source.get_class()) as Node
	if copy == null:
		return {"ok": false, "code": "godot_error", "error": "failed to instantiate duplicate node"}
	for property in MUTABLE_PROPERTIES:
		if _has_property(source, property) and _has_property(copy, property):
			copy.set(property, source.get(property))
	copy.name = node_name
	_mark_dedicated_node(copy)
	parent.add_child(copy)
	return {"ok": true, "result": {"node_path": String(copy.get_path()), "source": String(source.get_path()), "changed": true, "undoable": false}}

## 重命名当前场景中的专用节点。
static func rename(payload: Dictionary) -> Dictionary:
	var lookup := _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	if _is_protected_node(node):
		return {"ok": false, "code": "permission_denied", "error": "cannot rename protected runtime node"}
	if not _is_dedicated_target(node):
		return {"ok": false, "code": "permission_denied", "error": "only dedicated scene nodes may be renamed"}
	var name_result := _validate_node_name(String(payload.get("name", "")))
	if not bool(name_result.get("ok", false)):
		return name_result
	var node_name := String(name_result.name)
	if node.name == node_name:
		return {"ok": true, "result": {"node_path": String(node.get_path()), "changed": false, "undoable": false}}
	var parent := node.get_parent()
	if parent == null:
		return {"ok": false, "code": "permission_denied", "error": "node has no parent"}
	if parent.has_node(NodePath(node_name)):
		return {"ok": false, "code": "conflict", "error": "node name already exists: %s" % node_name}
	node.name = node_name
	return {"ok": true, "result": {"node_path": String(node.get_path()), "old_name": String(lookup.node_path).get_file(), "changed": true, "undoable": false}}

## 实现 runtime/assert/condition
##
## poll_ms 间隔检查条件是否满足;满足则返回 ok;超时返回 code=timeout。
static func assert_condition(payload: Dictionary) -> Dictionary:
	var condition: Variant = payload.get("condition", null)
	if typeof(condition) != TYPE_DICTIONARY:
		return {"ok": false, "code": "invalid_param", "error": "condition must be an object"}
	var timeout_ms: int = clampi(int(payload.get("timeout_ms", 1000)), 1, 30000)
	var poll_ms: int = clampi(int(payload.get("poll_ms", 20)), 5, 1000)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var verdict: Dictionary = Condition.evaluate(condition)
		if bool(verdict.get("ok", false)):
			var elapsed_ms: int = Time.get_ticks_msec() - (deadline - timeout_ms)
			return {"ok": true, "result": {"passed": true, "elapsed_ms": elapsed_ms}}
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(poll_ms / 1000.0)
		await t.timeout
	return {"ok": false, "code": "conflict", "error": "condition did not become true within timeout", "request_id": -1}

## 实现 runtime/assert/node_exists
static func assert_node_exists(payload: Dictionary) -> Dictionary:
	var node_path: String = String(payload.get("node_path", ""))
	var timeout_ms: int = clampi(int(payload.get("timeout_ms", 1000)), 1, 30000)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var lookup: Dictionary = _resolve(node_path)
		if bool(lookup.get("ok", false)):
			return {"ok": true, "result": {"passed": true, "node": String(lookup.node_path)}}
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(0.01)
		await t.timeout
	return {"ok": false, "code": "conflict", "error": "node did not appear within timeout"}

## 实现 runtime/assert/property_equals
static func assert_property_equals(payload: Dictionary) -> Dictionary:
	var node_path: String = String(payload.get("node_path", ""))
	var property: String = String(payload.get("property", ""))
	var expected: Variant = payload.get("value", null)
	var timeout_ms: int = clampi(int(payload.get("timeout_ms", 1000)), 1, 30000)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var lookup: Dictionary = _resolve(node_path)
		if bool(lookup.get("ok", false)) and _has_property(lookup.node, property):
			var got: Variant = lookup.node.get(property)
			if _variants_equal(got, expected):
				return {"ok": true, "result": {"passed": true, "value": got}}
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(0.01)
		await t.timeout
	return {"ok": false, "code": "conflict", "error": "property never matched expected value"}

## 实现 runtime/assert/signal_received
##
## 通过 _connect_pending_signal 记录已发出次数,count 达到则通过。
static func assert_signal_received(payload: Dictionary) -> Dictionary:
	var node_path: String = String(payload.get("node_path", ""))
	var signal_name: String = String(payload.get("signal", ""))
	var timeout_ms: int = clampi(int(payload.get("timeout_ms", 1000)), 1, 30000)
	var lookup: Dictionary = _resolve(node_path)
	if not bool(lookup.get("ok", false)):
		return lookup
	if signal_name.is_empty() or not _has_signal(lookup.node, signal_name):
		return {"ok": false, "code": "not_found", "error": "signal not declared: %s" % signal_name}
	var counter := [0]
	var proxy := func() -> void:
		counter[0] += 1
	lookup.node.connect(signal_name, proxy)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if counter[0] >= 1:
			break
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(0.01)
		await t.timeout
	if lookup.node.is_connected(signal_name, proxy):
		lookup.node.disconnect(signal_name, proxy)
	if counter[0] >= 1:
		return {"ok": true, "result": {"passed": true, "count": counter[0]}}
	return {"ok": false, "code": "conflict", "error": "signal was not emitted within timeout"}

## 实现 runtime/signal/connect
static func signal_connect(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var signal_name: String = String(payload.get("signal", ""))
	if not _has_signal(node, signal_name):
		return {"ok": false, "code": "not_found", "error": "signal not declared"}
	var target_path: String = String(payload.get("target", ""))
	var method_name: String = String(payload.get("method", ""))
	var target_lookup: Dictionary = _resolve(target_path)
	if not bool(target_lookup.get("ok", false)):
		return target_lookup
	var target_method: String = method_name if method_name != "" else "_on_signal"
	var allowlist: Variant = target_lookup.node.get_meta("gdapi_callable_methods", PackedStringArray())
	if not (allowlist is PackedStringArray) or not (target_method in allowlist):
		return {"ok": false, "code": "permission_denied", "error": "target method not in allowlist"}
	var bound: Callable = target_lookup.node.call.bind(target_method) if false else Callable(target_lookup.node, target_method)
	var err: int = node.connect(signal_name, bound)
	if err != OK:
		return {"ok": false, "code": "godot_error", "error": "connect failed with code %d" % err}
	return {"ok": true, "result": {"connected": true, "signal": signal_name}}

## 实现 runtime/signal/disconnect
static func signal_disconnect(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var signal_name: String = String(payload.get("signal", ""))
	var target_path: String = String(payload.get("target", ""))
	var method_name: String = String(payload.get("method", ""))
	if target_path.is_empty() or method_name.is_empty():
		return {"ok": false, "code": "missing_param", "error": "target and method are required"}
	var target_lookup: Dictionary = _resolve(target_path)
	if not bool(target_lookup.get("ok", false)):
		return target_lookup
	var bound: Callable = Callable(target_lookup.node, method_name)
	if not node.is_connected(signal_name, bound):
		return {"ok": false, "code": "not_found", "error": "callable is not connected to this signal"}
	node.disconnect(signal_name, bound)
	return {"ok": true, "result": {"disconnected": true}}

## 实现 runtime/signal/emit
static func signal_emit(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var signal_name: String = String(payload.get("signal", ""))
	if not _has_signal(node, signal_name):
		return {"ok": false, "code": "not_found", "error": "signal not declared"}
	var args: Array = payload.get("args", [])
	if args.is_empty():
		node.emit_signal(signal_name)
	elif args.size() == 1:
		node.emit_signal(signal_name, args[0])
	elif args.size() == 2:
		node.emit_signal(signal_name, args[0], args[1])
	elif args.size() == 3:
		node.emit_signal(signal_name, args[0], args[1], args[2])
	elif args.size() == 4:
		node.emit_signal(signal_name, args[0], args[1], args[2], args[3])
	else:
		return {"ok": false, "code": "invalid_param", "error": "args must contain 0..4 elements"}
	return {"ok": true, "result": {"emitted": signal_name, "arg_count": args.size()}}

## 实现 runtime/signal/await
##
## 一次性等待下次 emit,timeout_ms 超时则返回 code=timeout.
static func signal_await(payload: Dictionary) -> Dictionary:
	var lookup: Dictionary = _resolve(String(payload.get("node_path", "")))
	if not bool(lookup.get("ok", false)):
		return lookup
	var node: Node = lookup.node
	var signal_name: String = String(payload.get("signal", ""))
	var timeout_ms: int = clampi(int(payload.get("timeout_ms", 1000)), 1, 30000)
	if not _has_signal(node, signal_name):
		return {"ok": false, "code": "not_found", "error": "signal not declared"}
	var bucket: Array = []
	var proxy: Callable = func(_a0=null, _a1=null, _a2=null, _a3=null) -> void:
		bucket.append(1)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	node.connect(signal_name, proxy)
	while Time.get_ticks_msec() < deadline:
		if bucket.size() >= 1:
			break
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(0.01)
		await t.timeout
	if node.is_connected(signal_name, proxy):
		node.disconnect(signal_name, proxy)
	if bucket.is_empty():
		return {"ok": false, "code": "timeout", "error": "signal was not emitted within timeout"}
	return {"ok": true, "result": {"signal": signal_name}}

## 在 tree 中按 name/type/group 查找
static func _walk_find(node: Node, name: String, type_filter: String, group: String, out: Array, limit: int) -> void:
	if out.size() >= limit:
		return
	if (name == "" or String(node.name) == name) and (type_filter == "" or node.is_class(type_filter)) and (group == "" or node.is_in_group(group)):
		out.append({
			"path": String(node.get_path()),
			"type": node.get_class(),
			"name": String(node.name),
		})
	for child in node.get_children():
		if out.size() >= limit:
			return
		_walk_find(child, name, type_filter, group, out, limit)

## 解析绝对路径;返回 {ok:bool, node:Node?, node_path:String}
static func _resolve(node_path: String) -> Dictionary:
	if node_path.is_empty():
		return {"ok": false, "code": "missing_param", "error": "node_path is required"}
	if not node_path.begins_with("/root/"):
		return {"ok": false, "code": "invalid_param", "error": "node_path must start with /root/"}
	if node_path.contains("//") or node_path.contains("\\"):
		return {"ok": false, "code": "invalid_path", "error": "node_path contains an invalid separator"}
	for part in node_path.trim_prefix("/root/").split("/"):
		if part.is_empty() or part == "." or part == "..":
			return {"ok": false, "code": "invalid_path", "error": "node_path contains traversal segments"}
	var tree_root: Node = (Engine.get_main_loop() as SceneTree).root
	var rel: String = node_path.substr(("/root/").length())
	var pos: Node = tree_root.get_node_or_null(NodePath(rel))
	if pos == null:
		return {"ok": false, "code": "not_found", "error": "node not found: " + node_path}
	return {"ok": true, "node": pos, "node_path": node_path}

static func _scene_root() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	if tree.current_scene != null:
		return tree.current_scene
	return tree.root

static func _is_protected_node(node: Node) -> bool:
	if node == null:
		return true
	var tree := Engine.get_main_loop() as SceneTree
	if node == tree.root or node == _scene_root():
		return true
	if (
		String(node.name) == "GdApiRuntimeProbe"
		or String(node.name) in INFRASTRUCTURE_NODE_NAMES
		or String(node.name) in DEDICATED_FIXTURE_NODE_NAMES
	):
		return true
	var script := node.get_script()
	return script != null and String(script.resource_path).ends_with("/runtime_probe.gd")

static func _is_dedicated_target(node: Node) -> bool:
	var scene := _scene_root()
	if node == null or scene == null or node == scene or not scene.is_ancestor_of(node):
		return false
	if String(node.name) in DEDICATED_FIXTURE_NODE_NAMES and node.get_parent() == scene:
		_mark_dedicated_node(node)
		return true
	if _is_protected_node(node):
		return false
	if bool(node.get_meta(DEDICATED_NODE_META, false)):
		return true
	return false

static func _mark_dedicated_node(node: Node) -> void:
	node.set_meta(DEDICATED_NODE_META, true)

static func _is_mutable_property(property: String) -> bool:
	return property in MUTABLE_PROPERTIES

static func _validate_node_name(value: String) -> Dictionary:
	var name := value.strip_edges()
	if name.is_empty():
		return {"ok": false, "code": "missing_param", "error": "node name is required"}
	if name == "." or name == ".." or name.contains("/") or name.contains("\\"):
		return {"ok": false, "code": "invalid_param", "error": "node name must be a single path segment"}
	if name in ["root", "RuntimeMain", "GdApiRuntimeProbe"]:
		return {"ok": false, "code": "permission_denied", "error": "node name is protected: %s" % name}
	return {"ok": true, "name": name}

## 序列化一个 node -> dict
static func _serialize_node(node: Node, depth: int, max_depth: int, visited: Array) -> Dictionary:
	if visited.has(node):
		return {"name": String(node.name), "type": node.get_class(), "cycle": true}
	var path: Array = []
	var p: Node = node
	while p != null:
		path.append(String(p.name))
		p = p.get_parent()
	path.reverse()
	var entry: Dictionary = {
		"name": String(node.name),
		"type": node.get_class(),
		"path": "/" + "/".join(path).trim_prefix("/"),
		"children": [],
	}
	if depth < max_depth:
		var seen: Array = visited.duplicate()
		seen.append(node)
		for child in node.get_children():
			entry.children.append(_serialize_node(child, depth + 1, max_depth, seen))
	return entry

## 公开属性列表(去除 __ 类内部)
static func _public_properties(node: Node) -> Array:
	var result: Array = []
	for info in node.get_property_list():
		var n: String = String(info.name)
		if n.begins_with("_") or n == "script" or n == "script_variables" or info.usage & PROPERTY_USAGE_CATEGORY != 0:
			continue
		result.append(n)
	return result

## 判断 node 是否声明了 property
static func _has_property(node: Node, property: String) -> bool:
	for info in node.get_property_list():
		if String(info.name) == property:
			return true
	return false

## 判断 node 是否声明了 signal
static func _has_signal(node: Node, signal_name: String) -> bool:
	for s in node.get_signal_list():
		if String(s.name) == signal_name:
			return true
	return false

## 判断 candidate 是否在 root 之下（fallback=False 时仅查「不等于 candidate」）
static func _is_descendant_of(candidate: Node, root: Node, include_self: bool) -> bool:
	var p: Node = candidate
	if include_self:
		p = candidate
	else:
		p = candidate.get_parent()
	while p != null:
		if p == root:
			return true
		p = p.get_parent()
	return false

## 简单等价（Vector/Color/int/float 都由 compare 决定）
static func _variants_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Vector2 and b is Vector2:
		return (a - b).length() < 0.001
	if a is Vector3 and b is Vector3:
		return (a - b).length() < 0.001
	return a == b
