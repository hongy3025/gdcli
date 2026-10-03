@tool
class_name GdApiAudioEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const LAYOUT_PATH := "res://resources/audio_bus_layout.tres"


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
	AudioServer.add_bus()
	var index := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(index, bus_name)
	var saved := _save_layout("audio/bus/add")
	if not saved.ok:
		return saved
	return {"ok": true, "changed": true, "name": bus_name, "undoable": false}


static func remove_bus(name: Variant) -> Dictionary:
	if typeof(name) != TYPE_STRING or String(name).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var bus_name := String(name).strip_edges()
	var index := _bus_index(bus_name)
	if index < 0:
		return _error(ErrorCodes.NOT_FOUND, "audio bus not found")
	AudioServer.remove_bus(index)
	var saved := _save_layout("audio/bus/remove")
	if not saved.ok:
		return saved
	return {"ok": true, "changed": true, "name": bus_name, "undoable": false}


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
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(LAYOUT_PATH).get_base_dir()
	)
	var error := ResourceSaver.save(AudioServer.generate_bus_layout(), LAYOUT_PATH)
	if error != OK:
		AuditLog.record(route, "file", {}, false, ErrorCodes.GODOT_ERROR)
		return _error(ErrorCodes.GODOT_ERROR, "failed to save audio bus layout")
	AuditLog.record(route, "file", {"path": LAYOUT_PATH}, true)
	return {"ok": true}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
