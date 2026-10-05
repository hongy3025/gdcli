@tool
class_name GdApiAnimationTreeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const NodePathResolver := preload("res://addons/gdapi/runtime/services/node_path_resolver.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const BLEND_TYPES := [
	"AnimationNodeAnimation",
	"AnimationNodeBlend2",
	"AnimationNodeBlend3",
	"AnimationNodeOneShot",
	"AnimationNodeTimeScale",
	"AnimationNodeTimeSeek",
	"AnimationNodeAdd2",
	"AnimationNodeAdd3",
	"AnimationNodeSub2"
]


## tree_path 同时接受场景根相对路径与 node/* 回传的绝对用户路径。
static func tree(path: String) -> Dictionary:
	var found := NodePathResolver.resolve(path)
	if not found.ok:
		return {"ok": false, "code": found.code, "error": found.error}
	if not found.node is AnimationTree:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "AnimationTree not found"}
	return {"ok": true, "tree": found.node}


static func set_blend(path: String, parameter: String, value: Variant) -> Dictionary:
	if not parameter.begins_with("parameters/") or not parameter.ends_with("/blend_position"):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "parameter must be a blend_position path"
		}
	var found := tree(path)
	if not found.ok:
		return found
	var state_name := parameter.trim_prefix("parameters/").trim_suffix("/blend_position")
	if state_name.is_empty() or "/" in state_name:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "parameter must address one direct state-machine node"
		}
	var machine = found.tree.tree_root
	if not machine is AnimationNodeStateMachine or not machine.has_node(StringName(state_name)):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "blend state not found"}
	var blend_node = machine.get_node(StringName(state_name))
	if not (blend_node is AnimationNodeBlendSpace1D or blend_node is AnimationNodeBlendSpace2D):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "state must be an AnimationNodeBlendSpace"
		}
	var result := EditAction.commit_property(
		found.tree, StringName(parameter), value, "gdcli: set animation blend"
	)
	if not result.ok:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": result.error}
	return {"ok": true, "changed": true, "undoable": true, "parameter": parameter}


static func add_state(path: String, name: String) -> Dictionary:
	if name.is_empty():
		return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "name is required"}
	return _mutate_state_machine(
		path,
		"gdcli: add animation tree state",
		func(machine: AnimationNodeStateMachine) -> Dictionary:
			if machine.has_node(StringName(name)):
				return {"ok": false, "code": ErrorCodes.CONFLICT, "error": "state already exists"}
			machine.add_node(StringName(name), AnimationNodeAnimation.new(), Vector2.ZERO)
			return {"ok": true, "name": name}
	)


static func add_transition(path: String, from: String, to: String) -> Dictionary:
	if from.is_empty() or to.is_empty():
		return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "from and to are required"}
	return _mutate_state_machine(
		path,
		"gdcli: add animation tree transition",
		func(machine: AnimationNodeStateMachine) -> Dictionary:
			if not machine.has_node(StringName(from)) or not machine.has_node(StringName(to)):
				return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "state not found"}
			if from == to or machine.has_transition(StringName(from), StringName(to)):
				return {
					"ok": false,
					"code": ErrorCodes.CONFLICT,
					"error": "invalid or duplicate transition"
				}
			machine.add_transition(
				StringName(from), StringName(to), AnimationNodeStateMachineTransition.new()
			)
			return {"ok": true, "from": from, "to": to}
	)


static func _mutate_state_machine(path: String, action: String, callback: Callable) -> Dictionary:
	var found := tree(path)
	if not found.ok:
		return found
	var before = found.tree.tree_root
	if not before is AnimationNodeStateMachine:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "AnimationTree tree_root must be AnimationNodeStateMachine"
		}
	var after: AnimationNodeStateMachine = before.duplicate(true)
	var verdict: Dictionary = callback.call(after)
	if not verdict.ok:
		return verdict
	var result := EditAction.commit_property(found.tree, &"tree_root", after, action)
	if not result.ok:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": result.error}
	return {"ok": true, "changed": true, "undoable": true}.merged(verdict)


static func remove_state(path: String, name: String) -> Dictionary:
	if name in ["Start", "End"] or name.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "cannot remove reserved/empty state")
	return _mutate_state_machine(
		path,
		"gdcli: remove animation tree state",
		func(machine: AnimationNodeStateMachine) -> Dictionary:
			if not machine.has_node(StringName(name)):
				return _error(ErrorCodes.NOT_FOUND, "state not found")
			machine.remove_node(StringName(name))
			return {"ok": true, "name": name}
	)


static func remove_transition(path: String, from: String, to: String) -> Dictionary:
	return _mutate_state_machine(
		path,
		"gdcli: remove animation tree transition",
		func(machine: AnimationNodeStateMachine) -> Dictionary:
			if not machine.has_transition(StringName(from), StringName(to)):
				return _error(ErrorCodes.NOT_FOUND, "transition not found")
			machine.remove_transition(StringName(from), StringName(to))
			return {"ok": true, "from": from, "to": to}
	)


# gdlint: ignore=max-returns
static func blend_tree(payload: Dictionary, operation: String) -> Dictionary:
	if typeof(payload.get("tree_path")) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "tree_path must be a string")
	var found := tree(payload.tree_path)
	if not found.ok:
		return found
	var target: AnimationTree = found.tree
	if operation == "create":
		if target.tree_root is AnimationNodeBlendTree:
			return _error(ErrorCodes.CONFLICT, "blend tree already exists")
		return _commit_blend(target, AnimationNodeBlendTree.new(), {}, operation)
	if not target.tree_root is AnimationNodeBlendTree:
		return _error(ErrorCodes.INVALID_PARAM, "tree_root is not AnimationNodeBlendTree")
	if operation == "get":
		return {"ok": true}.merged(_blend_info(target))
	var graph: AnimationNodeBlendTree = target.tree_root.duplicate(true)
	var parameters: Dictionary = {}
	match operation:
		"add", "set":
			var name: Variant = payload.get("name")
			if typeof(name) != TYPE_STRING or not _valid_name(name) or name == "output":
				return _error(
					ErrorCodes.INVALID_PARAM, "name must be a nonreserved graph identifier"
				)
			var node: AnimationNode
			if operation == "add":
				if graph.has_node(StringName(name)):
					return _error(ErrorCodes.CONFLICT, "blend node already exists")
				var type_name: Variant = payload.get("type")
				if type_name not in BLEND_TYPES:
					return _error(ErrorCodes.INVALID_PARAM, "unsupported blend node type")
				node = ClassDB.instantiate(type_name)
				var position := Codec.decode(
					payload.get("position", {"type": "Vector2", "value": [0, 0]})
				)
				if (
					not position.ok
					or not position.value is Vector2
					or not position.value.is_finite()
				):
					return _error(ErrorCodes.INVALID_PARAM, "position must be finite Vector2")
				graph.add_node(StringName(name), node, position.value)
			else:
				if not graph.has_node(StringName(name)):
					return _error(ErrorCodes.NOT_FOUND, "blend node not found")
				node = graph.get_node(StringName(name))
			var configured := _configure_node(node, payload.get("properties", {}))
			if not configured.ok:
				return configured
			if node is AnimationNodeAnimation and not String(node.animation).is_empty():
				var player := target.get_node_or_null(target.anim_player)
				if not player is AnimationPlayer or not player.has_animation(node.animation):
					return _error(
						ErrorCodes.NOT_FOUND, "animation does not exist in AnimationTree player"
					)
			var runtime_values: Variant = payload.get("parameters", {})
			if typeof(runtime_values) != TYPE_DICTIONARY:
				return _error(ErrorCodes.INVALID_PARAM, "parameters must be an object")
			for key in runtime_values:
				if not _valid_name(str(key)):
					return _error(
						ErrorCodes.INVALID_PARAM, "parameter must be a direct node parameter"
					)
				parameters["parameters/" + name + "/" + str(key)] = runtime_values[key]
		"remove":
			var name: Variant = payload.get("name")
			if typeof(name) != TYPE_STRING or name == "output":
				return _error(ErrorCodes.INVALID_PARAM, "cannot remove output")
			if not graph.has_node(StringName(name)):
				return _error(ErrorCodes.NOT_FOUND, "blend node not found")
			graph.remove_node(StringName(name))
		"connect", "disconnect":
			var input: Variant = payload.get("input_node")
			var output: Variant = payload.get("output_node")
			var port: Variant = payload.get("input_index")
			if typeof(input) != TYPE_STRING or not graph.has_node(StringName(input)):
				return _error(ErrorCodes.NOT_FOUND, "input_node not found")
			if (
				typeof(port) not in [TYPE_INT, TYPE_FLOAT]
				or not is_finite(float(port))
				or float(port) != floor(float(port))
				or int(port) < 0
				or int(port) >= graph.get_node(StringName(input)).get_input_count()
			):
				return _error(ErrorCodes.INVALID_PARAM, "input_index outside node input ports")
			var connections := _connections(graph)
			var occupied := false
			for connection in connections:
				if connection.input_node == input and connection.input_index == int(port):
					occupied = true
			if operation == "disconnect":
				if not occupied:
					return _error(ErrorCodes.NOT_FOUND, "connection not found")
				graph.disconnect_node(StringName(input), int(port))
			else:
				if (
					typeof(output) != TYPE_STRING
					or output == "output"
					or not graph.has_node(StringName(output))
				):
					return _error(ErrorCodes.NOT_FOUND, "output_node not found or reserved")
				if occupied:
					return _error(ErrorCodes.CONFLICT, "input port already connected")
				for connection in connections:
					if connection.output_node == output:
						return _error(ErrorCodes.CONFLICT, "output is already connected")
				if input == output or _depends_on(connections, String(output), String(input), {}):
					return _error(ErrorCodes.CONFLICT, "connection would create a cycle")
				graph.connect_node(StringName(input), int(port), StringName(output))
		_:
			return _error(ErrorCodes.INVALID_PARAM, "unknown blend tree operation")
	return _commit_blend(target, graph, parameters, operation)


# gdlint: ignore=max-returns
static func _configure_node(node: AnimationNode, properties: Variant) -> Dictionary:
	if typeof(properties) != TYPE_DICTIONARY:
		return _error(ErrorCodes.INVALID_PARAM, "properties must be an object")
	for key in properties:
		var metadata: Dictionary = {}
		for entry in node.get_property_list():
			if (
				String(entry.name) == str(key)
				and entry.usage & PROPERTY_USAGE_STORAGE
				and not (entry.usage & PROPERTY_USAGE_READ_ONLY)
				and entry.type not in [TYPE_OBJECT, TYPE_NIL]
				and not str(key).begins_with("resource_")
				and str(key) != "script"
			):
				metadata = entry
				break
		if metadata.is_empty():
			return _error(
				ErrorCodes.INVALID_PARAM, "unknown or protected node property: " + str(key)
			)
		var decoded := Codec.decode(properties[key])
		if not decoded.ok:
			return _error(ErrorCodes.INVALID_PARAM, decoded.error)
		var value: Variant = decoded.value
		if metadata.type == TYPE_STRING_NAME and typeof(value) == TYPE_STRING:
			value = StringName(value)
		elif metadata.type == TYPE_FLOAT and typeof(value) in [TYPE_INT, TYPE_FLOAT]:
			value = float(value)
		elif (
			metadata.type == TYPE_INT
			and typeof(value) in [TYPE_INT, TYPE_FLOAT]
			and is_finite(float(value))
			and float(value) == floor(float(value))
		):
			value = int(value)
		if (
			typeof(value) != metadata.type
			or (typeof(value) in [TYPE_INT, TYPE_FLOAT] and not is_finite(float(value)))
		):
			return _error(ErrorCodes.INVALID_PARAM, "node property type mismatch: " + str(key))
		if metadata.hint == PROPERTY_HINT_RANGE:
			var bounds := String(metadata.hint_string).split(",")
			if (
				bounds.size() >= 2
				and (float(value) < float(bounds[0]) or float(value) > float(bounds[1]))
			):
				return _error(ErrorCodes.INVALID_PARAM, "node property outside allowed range")
		if (
			metadata.type == TYPE_INT
			and metadata.hint == PROPERTY_HINT_ENUM
			and (int(value) < 0 or int(value) >= String(metadata.hint_string).split(",").size())
		):
			return _error(ErrorCodes.INVALID_PARAM, "invalid node property enum")
		node.set(key, value)
		if node.get(key) != value:
			return _error(ErrorCodes.GODOT_ERROR, "node rejected property: " + str(key))
	return {"ok": true}


# gdlint: ignore=max-returns
static func _commit_blend(
	target: AnimationTree, graph: AnimationNodeBlendTree, parameters: Dictionary, operation: String
) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	var before: AnimationRootNode = target.tree_root
	var previous: Dictionary = {}
	for entry in target.get_property_list():
		if String(entry.name).begins_with("parameters/"):
			previous[String(entry.name)] = target.get(entry.name)
	target.tree_root = graph
	var decoded_values: Dictionary = {}
	for key in parameters:
		var metadata: Dictionary = {}
		for entry in target.get_property_list():
			if (
				String(entry.name) == key
				and entry.type != TYPE_OBJECT
				and not (entry.usage & PROPERTY_USAGE_READ_ONLY)
			):
				metadata = entry
				break
		var decoded := Codec.decode(parameters[key])
		if metadata.is_empty() or not decoded.ok:
			_restore_tree(target, before, previous)
			return _error(ErrorCodes.INVALID_PARAM, "unknown or invalid blend parameter: " + key)
		var value: Variant = decoded.value
		if metadata.type == TYPE_FLOAT and typeof(value) in [TYPE_INT, TYPE_FLOAT]:
			value = float(value)
		elif (
			metadata.type == TYPE_INT
			and typeof(value) in [TYPE_INT, TYPE_FLOAT]
			and is_finite(float(value))
			and float(value) == floor(float(value))
		):
			value = int(value)
		if (
			typeof(value) != metadata.type
			or (typeof(value) in [TYPE_INT, TYPE_FLOAT] and not is_finite(float(value)))
		):
			_restore_tree(target, before, previous)
			return _error(ErrorCodes.INVALID_PARAM, "blend parameter type mismatch: " + key)
		if metadata.hint == PROPERTY_HINT_RANGE:
			var bounds := String(metadata.hint_string).split(",")
			if (
				bounds.size() >= 2
				and (
					(float(value) < float(bounds[0]) and not "or_less" in bounds)
					or (float(value) > float(bounds[1]) and not "or_greater" in bounds)
				)
			):
				_restore_tree(target, before, previous)
				return _error(ErrorCodes.INVALID_PARAM, "blend parameter outside allowed range")
		if (
			metadata.type == TYPE_INT
			and metadata.hint == PROPERTY_HINT_ENUM
			and (int(value) < 0 or int(value) >= String(metadata.hint_string).split(",").size())
		):
			_restore_tree(target, before, previous)
			return _error(ErrorCodes.INVALID_PARAM, "invalid blend parameter enum")
		decoded_values[key] = value
		target.set(key, value)
		if target.get(key) != value:
			_restore_tree(target, before, previous)
			return _error(ErrorCodes.GODOT_ERROR, "AnimationTree rejected parameter")
	manager.create_action("gdcli: blend tree " + operation, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_property(target, &"tree_root", graph)
	for key in decoded_values:
		manager.add_do_property(target, StringName(key), decoded_values[key])
	manager.add_undo_property(target, &"tree_root", before)
	for key in previous:
		manager.add_undo_property(target, StringName(key), previous[key])
	manager.commit_action(false)
	return {"ok": true, "changed": true, "undoable": true}.merged(_blend_info(target))


static func _restore_tree(
	target: AnimationTree, root: AnimationRootNode, parameters: Dictionary
) -> void:
	target.tree_root = root
	for key in parameters:
		target.set(key, parameters[key])


static func _blend_info(target: AnimationTree) -> Dictionary:
	var graph: AnimationNodeBlendTree = target.tree_root
	var nodes: Array = []
	for name in graph.get_node_list():
		var node := graph.get_node(name)
		var properties: Dictionary = {}
		for entry in node.get_property_list():
			if (
				entry.usage & PROPERTY_USAGE_STORAGE
				and entry.type not in [TYPE_OBJECT, TYPE_NIL]
				and not String(entry.name).begins_with("resource_")
			):
				properties[String(entry.name)] = Codec.from_variant(node.get(entry.name))
		nodes.append(
			{
				"name": String(name),
				"type": node.get_class(),
				"position": Codec.from_variant(graph.get_node_position(name)),
				"properties": properties
			}
		)
	var parameters: Dictionary = {}
	for entry in target.get_property_list():
		if String(entry.name).begins_with("parameters/") and entry.type != TYPE_OBJECT:
			parameters[String(entry.name)] = Codec.from_variant(target.get(entry.name))
	return {"nodes": nodes, "connections": _connections(graph), "parameters": parameters}


static func _connections(graph: AnimationNodeBlendTree) -> Array:
	var raw: Array = graph.get("node_connections")
	var connections: Array = []
	for index in range(0, raw.size(), 3):
		connections.append(
			{
				"input_node": String(raw[index]),
				"input_index": int(raw[index + 1]),
				"output_node": String(raw[index + 2])
			}
		)
	return connections


static func _depends_on(
	connections: Array, node: String, target: String, visited: Dictionary
) -> bool:
	if node == target:
		return true
	if visited.has(node):
		return false
	visited[node] = true
	for connection in connections:
		if (
			connection.input_node == node
			and _depends_on(connections, connection.output_node, target, visited)
		):
			return true
	return false


static func _valid_name(name: String) -> bool:
	return (
		not name.is_empty()
		and not name.contains("/")
		and not name.contains(".")
		and not name.contains(":")
	)


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
