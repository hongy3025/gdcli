@tool
class_name GdApiAudioEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")


static func list_buses() -> Dictionary:
	var names: Array = []
	for index in range(AudioServer.get_bus_count()):
		names.append(AudioServer.get_bus_name(index))
	names.sort()
	return {"ok": true, "buses": names, "undoable": false}


static func add_bus(name: Variant) -> Dictionary:
	if typeof(name) != TYPE_STRING or String(name).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var bus_name := String(name).strip_edges()
	if bus_name == "Master":
		return _error(ErrorCodes.CONFLICT, "Master bus already exists")
	if _bus_index(bus_name) >= 0:
		return _error(ErrorCodes.CONFLICT, "audio bus already exists")
	var before := AudioServer.generate_bus_layout()
	AudioServer.add_bus()
	var index := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, "Master")
	return _commit_layout(before, "audio/bus/add").merged({"name": bus_name})


static func remove_bus(name: Variant) -> Dictionary:
	if typeof(name) != TYPE_STRING or String(name).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var bus_name := String(name).strip_edges()
	var index := _bus_index(bus_name)
	if index < 0:
		return _error(ErrorCodes.NOT_FOUND, "audio bus not found")
	if index == 0:
		return _error(ErrorCodes.PERMISSION_DENIED, "Master bus cannot be removed")
	var before := AudioServer.generate_bus_layout()
	for other in range(AudioServer.get_bus_count()):
		if AudioServer.get_bus_send(other) == bus_name:
			AudioServer.set_bus_send(other, "Master")
	AudioServer.remove_bus(index)
	return _commit_layout(before, "audio/bus/remove").merged({"name": bus_name})


static func create_player(parent_path: Variant, name: Variant, stream_path: Variant) -> Dictionary:
	if typeof(name) != TYPE_STRING or String(name).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var parent := NodeEditor.find(
		(
			String(parent_path)
			if typeof(parent_path) == TYPE_STRING and not String(parent_path).is_empty()
			else "/root/AudioDomain"
		)
	)
	if not parent.ok:
		return parent
	if typeof(stream_path) != TYPE_STRING or not ResourceLoader.exists(String(stream_path)):
		return _error(ErrorCodes.NOT_FOUND, "audio stream not found")
	var stream := ResourceLoader.load(String(stream_path))
	if not stream is AudioStream:
		return _error(ErrorCodes.INVALID_PARAM, "resource is not an AudioStream")
	var player := AudioStreamPlayer.new()
	player.name = String(name)
	player.stream = stream
	var owner := EditorInterface.get_edited_scene_root()
	var manager := EditAction.undo_redo()
	if manager == null:
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	manager.create_action("gdcli: create audio player", UndoRedo.MERGE_DISABLE, owner)
	manager.add_do_method(parent.node, "add_child", player, true)
	manager.add_do_method(player, "set_owner", owner)
	manager.add_do_reference(player)
	manager.add_undo_method(parent.node, "remove_child", player)
	manager.commit_action()
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"name": player.name,
		"node_path": _user_path(player)
	}


## 返回编辑器场景内的用户路径（/root/<场景根>/...），与 node/* 路由一致；
## 直接返回编辑器内部路径（/root/@EditorNode@...）会无法再被其它路由解析。
static func _user_path(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return str(node.get_path())
	if node == root:
		return "/root/" + String(root.name)
	return "/root/" + String(root.name) + "/" + String(root.get_path_to(node))


## 在编辑器当前场景中触发播放,返回节点真实的 AudioStreamPlayer.playing 状态。
static func play(node_path: Variant) -> Dictionary:
	var player := _player(node_path)
	if not player.ok:
		return player
	var target: AudioStreamPlayer = player.node
	target.play()
	return {"ok": true, "changed": true, "playing": target.playing, "undoable": false}


## 在编辑器当前场景中停止播放,返回节点真实的 AudioStreamPlayer.playing 状态。
static func stop(node_path: Variant) -> Dictionary:
	var player := _player(node_path)
	if not player.ok:
		return player
	var target: AudioStreamPlayer = player.node
	target.stop()
	return {"ok": true, "changed": true, "playing": target.playing, "undoable": false}


static func _player(node_path: Variant) -> Dictionary:
	if typeof(node_path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "node_path must be a string")
	var found := NodeEditor.find(String(node_path))
	if not found.ok:
		return found
	if not found.node is AudioStreamPlayer:
		return _error(ErrorCodes.NOT_SUPPORTED, "node must be AudioStreamPlayer")
	if found.node.stream == null:
		return _error(ErrorCodes.NOT_FOUND, "audio player has no stream")
	return found


static func _bus_index(name: String) -> int:
	for index in range(AudioServer.get_bus_count()):
		if AudioServer.get_bus_name(index) == name:
			return index
	return -1


static func _save_layout(route: String) -> Dictionary:
	return ResourceEditor.save_verified(AudioServer.generate_bus_layout(), _layout_path(), route)


static func get_bus(name: Variant) -> Dictionary:
	var lookup := _lookup_bus(name)
	if not lookup.ok:
		return lookup
	var index: int = lookup.index
	var effects: Array = []
	for slot in range(AudioServer.get_bus_effect_count(index)):
		effects.append(_effect_info(index, slot))
	return {
		"ok": true,
		"index": index,
		"name": String(name),
		"volume_db": AudioServer.get_bus_volume_db(index),
		"mute": AudioServer.is_bus_mute(index),
		"solo": AudioServer.is_bus_solo(index),
		"bypass": AudioServer.is_bus_bypassing_effects(index),
		"send": String(AudioServer.get_bus_send(index)),
		"effects": effects
	}


# gdlint: ignore=max-returns
static func set_bus(payload: Dictionary) -> Dictionary:
	var lookup := _lookup_bus(payload.get("name"))
	if not lookup.ok:
		return lookup
	var index: int = lookup.index
	var properties: Variant = payload.get("properties")
	if typeof(properties) != TYPE_DICTIONARY or properties.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "properties must be a nonempty object")
	for key in properties:
		var value: Variant = properties[key]
		match key:
			"volume_db":
				if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
					return _error(ErrorCodes.INVALID_PARAM, "volume_db must be finite")
			"mute", "solo", "bypass":
				if typeof(value) != TYPE_BOOL:
					return _error(ErrorCodes.INVALID_PARAM, key + " must be boolean")
			"send":
				if index == 0 or typeof(value) != TYPE_STRING or _bus_index(value) < 0:
					return _error(
						ErrorCodes.INVALID_PARAM,
						"send must name an existing bus; Master has no send"
					)
				var cursor := String(value)
				var visited: Dictionary = {}
				while cursor != "Master":
					if cursor == String(payload.name) or visited.has(cursor):
						return _error(ErrorCodes.CONFLICT, "audio bus send would create a cycle")
					visited[cursor] = true
					var next := _bus_index(cursor)
					if next < 0:
						break
					cursor = String(AudioServer.get_bus_send(next))
					if cursor.is_empty():
						cursor = "Master"
			_:
				return _error(ErrorCodes.INVALID_PARAM, "unknown bus property: " + str(key))
	var before := AudioServer.generate_bus_layout()
	for key in properties:
		match key:
			"volume_db":
				AudioServer.set_bus_volume_db(index, float(properties[key]))
			"mute":
				AudioServer.set_bus_mute(index, properties[key])
			"solo":
				AudioServer.set_bus_solo(index, properties[key])
			"bypass":
				AudioServer.set_bus_bypass_effects(index, properties[key])
			"send":
				AudioServer.set_bus_send(index, properties[key])
	var committed := _commit_layout(before, "audio/bus/set")
	return committed.merged(get_bus(payload.name)) if committed.ok else committed


# gdlint: ignore=max-returns
static func effect(payload: Dictionary, operation: String) -> Dictionary:
	var lookup := _lookup_bus(payload.get("name"))
	if not lookup.ok:
		return lookup
	var index: int = lookup.index
	var count := AudioServer.get_bus_effect_count(index)
	var slot: Variant = payload.get("slot", count if operation == "add" else null)
	if (
		typeof(slot) not in [TYPE_INT, TYPE_FLOAT]
		or not is_finite(float(slot))
		or float(slot) != floor(float(slot))
		or int(slot) < 0
		or int(slot) > count
		or (operation != "add" and int(slot) == count)
	):
		return _error(ErrorCodes.INVALID_PARAM, "slot is outside the effect list")
	var effect_resource: AudioEffect
	if operation == "add":
		var type_name: Variant = payload.get("type")
		if (
			typeof(type_name) != TYPE_STRING
			or not ClassDB.class_exists(type_name)
			or not ClassDB.is_parent_class(type_name, "AudioEffect")
			or not ClassDB.can_instantiate(type_name)
		):
			return _error(ErrorCodes.INVALID_PARAM, "type must be an instantiable AudioEffect")
		effect_resource = ClassDB.instantiate(type_name)
	elif operation in ["set", "get"]:
		effect_resource = AudioServer.get_bus_effect(index, int(slot))
	if operation == "get":
		return {"ok": true}.merged(_effect_info(index, int(slot)))
	if operation in ["add", "set"]:
		effect_resource = effect_resource.duplicate(true)
		var validated := _set_effect_parameters(effect_resource, payload.get("parameters", {}))
		if not validated.ok:
			return validated
	if payload.has("enabled") and typeof(payload.enabled) != TYPE_BOOL:
		return _error(ErrorCodes.INVALID_PARAM, "enabled must be boolean")
	var before := AudioServer.generate_bus_layout()
	match operation:
		"add":
			AudioServer.add_bus_effect(index, effect_resource, int(slot))
			AudioServer.set_bus_effect_enabled(index, int(slot), payload.get("enabled", true))
		"set":
			var enabled := AudioServer.is_bus_effect_enabled(index, int(slot))
			AudioServer.remove_bus_effect(index, int(slot))
			AudioServer.add_bus_effect(index, effect_resource, int(slot))
			AudioServer.set_bus_effect_enabled(index, int(slot), payload.get("enabled", enabled))
		"remove":
			AudioServer.remove_bus_effect(index, int(slot))
		"enable":
			if not payload.has("enabled"):
				return _error(ErrorCodes.MISSING_PARAM, "enabled is required")
			AudioServer.set_bus_effect_enabled(index, int(slot), payload.enabled)
		_:
			return _error(ErrorCodes.INVALID_PARAM, "unknown effect operation")
	var committed := _commit_layout(before, "audio/bus/effect/" + operation)
	if committed.ok:
		committed["slot"] = int(slot)
		if operation != "remove":
			committed.merge(_effect_info(index, int(slot)))
	return committed


# gdlint: ignore=max-returns
static func _set_effect_parameters(effect_resource: AudioEffect, parameters: Variant) -> Dictionary:
	if typeof(parameters) != TYPE_DICTIONARY:
		return _error(ErrorCodes.INVALID_PARAM, "parameters must be an object")
	for name in parameters:
		var property: Dictionary = {}
		for entry in effect_resource.get_property_list():
			if (
				String(entry.name) == str(name)
				and entry.usage & PROPERTY_USAGE_STORAGE
				and not (entry.usage & PROPERTY_USAGE_READ_ONLY)
				and entry.type not in [TYPE_OBJECT, TYPE_NIL]
				and not str(name).begins_with("resource_")
			):
				property = entry
				break
		if property.is_empty():
			return _error(
				ErrorCodes.INVALID_PARAM, "unknown or protected effect parameter: " + str(name)
			)
		var decoded := Codec.decode(parameters[name])
		if not decoded.ok:
			return _error(ErrorCodes.INVALID_PARAM, decoded.error)
		var value: Variant = decoded.value
		if property.type == TYPE_FLOAT and typeof(value) in [TYPE_INT, TYPE_FLOAT]:
			value = float(value)
		elif (
			property.type == TYPE_INT
			and typeof(value) in [TYPE_INT, TYPE_FLOAT]
			and is_finite(float(value))
			and float(value) == floor(float(value))
		):
			value = int(value)
		if (
			typeof(value) != property.type
			or (typeof(value) in [TYPE_INT, TYPE_FLOAT] and not is_finite(float(value)))
		):
			return _error(ErrorCodes.INVALID_PARAM, "parameter type mismatch: " + str(name))
		if property.hint == PROPERTY_HINT_RANGE:
			var bounds := String(property.hint_string).split(",")
			if (
				bounds.size() >= 2
				and (
					(float(value) < float(bounds[0]) and not bounds.has("or_less"))
					or (float(value) > float(bounds[1]) and not bounds.has("or_greater"))
				)
			):
				return _error(
					ErrorCodes.INVALID_PARAM, "parameter outside allowed range: " + str(name)
				)
		if (
			property.hint == PROPERTY_HINT_ENUM
			and (int(value) < 0 or int(value) >= String(property.hint_string).split(",").size())
		):
			return _error(ErrorCodes.INVALID_PARAM, "invalid parameter enum: " + str(name))
		effect_resource.set(name, value)
		if effect_resource.get(name) != value:
			return _error(ErrorCodes.GODOT_ERROR, "effect rejected parameter: " + str(name))
	return {"ok": true}


static func _effect_info(index: int, slot: int) -> Dictionary:
	var resource := AudioServer.get_bus_effect(index, slot)
	var parameters: Dictionary = {}
	for property in resource.get_property_list():
		if (
			property.usage & PROPERTY_USAGE_STORAGE
			and property.type not in [TYPE_OBJECT, TYPE_NIL]
			and not String(property.name).begins_with("resource_")
		):
			parameters[String(property.name)] = Codec.from_variant(resource.get(property.name))
	return {
		"slot": slot,
		"type": resource.get_class(),
		"enabled": AudioServer.is_bus_effect_enabled(index, slot),
		"parameters": parameters
	}


static func _lookup_bus(name: Variant) -> Dictionary:
	if typeof(name) != TYPE_STRING or String(name).is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var index := _bus_index(name)
	return (
		{"ok": true, "index": index}
		if index >= 0
		else _error(ErrorCodes.NOT_FOUND, "audio bus not found")
	)


static func _commit_layout(before: AudioBusLayout, route: String) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		AudioServer.set_bus_layout(before)
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	var after := AudioServer.generate_bus_layout()
	var saved := _save_layout(route)
	if not saved.ok:
		AudioServer.set_bus_layout(before)
		return saved
	var transaction := GdApiAudioEditor.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	manager.create_action("gdcli: " + route, UndoRedo.MERGE_DISABLE, scene_root)
	if scene_root != null:
		manager.force_fixed_history()
	manager.add_do_method(transaction, "_apply_layout", after, route)
	manager.add_undo_method(transaction, "_apply_layout", before, route)
	manager.add_do_reference(transaction)
	manager.commit_action(false)
	return {"ok": true, "changed": true, "undoable": true, "layout_path": _layout_path()}


func _apply_layout(layout: AudioBusLayout, route: String) -> void:
	var before := AudioServer.generate_bus_layout()
	AudioServer.set_bus_layout(layout)
	var saved := _save_layout(route)
	if not saved.ok:
		AudioServer.set_bus_layout(before)
		push_error(saved.error)


static func _layout_path() -> String:
	return String(
		ProjectSettings.get_setting("audio/default_bus_layout", "res://default_bus_layout.tres")
	)


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
