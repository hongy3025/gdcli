@tool
class_name GdApiAnimationEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

static func player(path: String) -> Dictionary:
	var root := SceneEditor.current_root()
	if root == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	var node := root.get_node_or_null(NodePath(path))
	if node == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "AnimationPlayer not found"}
	if not node is AnimationPlayer:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "node must be AnimationPlayer"}
	return {"ok": true, "player": node}

static func create(player_path: String, name: String) -> Dictionary:
	if name.is_empty(): return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "name is required"}
	var found := player(player_path)
	if not found.ok: return found
	var target: AnimationPlayer = found.player
	if target.has_animation(name): return {"ok": false, "code": ErrorCodes.CONFLICT, "error": "animation already exists"}
	return _replace(target, name, null, Animation.new(), "gdcli: create animation")

static func remove(player_path: String, name: String) -> Dictionary:
	var found := player(player_path)
	if not found.ok: return found
	var target: AnimationPlayer = found.player
	if not target.has_animation(name): return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "animation not found"}
	return _replace(target, name, target.get_animation(name).duplicate(true), null, "gdcli: delete animation")

static func mutate(player_path: String, name: String, action: String, callback: Callable) -> Dictionary:
	var found := player(player_path)
	if not found.ok: return found
	var target: AnimationPlayer = found.player
	if not target.has_animation(name): return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "animation not found"}
	var before: Animation = target.get_animation(name).duplicate(true)
	var after: Animation = before.duplicate(true)
	var verdict: Dictionary = callback.call(after)
	if not verdict.ok: return verdict
	return _replace(target, name, before, after, action, verdict)

static func add_track(player_path: String, name: String, path: String) -> Dictionary:
	if path.is_empty(): return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "path is required"}
	return mutate(player_path, name, "gdcli: add animation track", func(animation: Animation) -> Dictionary:
		var index := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(index, NodePath(path))
		return {"ok": true, "track_index": index}
	)

static func remove_track(player_path: String, name: String, track_index: int) -> Dictionary:
	return mutate(player_path, name, "gdcli: remove animation track", func(animation: Animation) -> Dictionary:
		if track_index < 0 or track_index >= animation.get_track_count():
			return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "track not found"}
		animation.remove_track(track_index)
		return {"ok": true, "track_index": track_index}
	)

static func add_key(player_path: String, name: String, track_index: int, time: float, value: Variant) -> Dictionary:
	return mutate(player_path, name, "gdcli: add animation key", func(animation: Animation) -> Dictionary:
		if track_index < 0 or track_index >= animation.get_track_count() or time < 0.0:
			return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "invalid track_index or time"}
		var key_index := animation.track_insert_key(track_index, time, value)
		return {"ok": true, "track_index": track_index, "key_index": key_index}
	)

static func remove_key(player_path: String, name: String, track_index: int, time: float) -> Dictionary:
	return mutate(player_path, name, "gdcli: remove animation key", func(animation: Animation) -> Dictionary:
		if track_index < 0 or track_index >= animation.get_track_count():
			return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "track not found"}
		var key_index := animation.track_find_key(track_index, time, Animation.FIND_MODE_EXACT)
		if key_index < 0: return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "key not found"}
		animation.track_remove_key(track_index, key_index)
		return {"ok": true, "track_index": track_index, "key_index": key_index}
	)

static func _replace(target: AnimationPlayer, name: String, before: Animation, after: Animation, action: String, extra: Dictionary = {}) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null: return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var holder := GdApiAnimationEditor.new()
	manager.create_action(action, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_method(holder, "apply", target, name, after)
	manager.add_undo_method(holder, "apply", target, name, before)
	manager.commit_action()
	var result := {"ok": true, "changed": true, "undoable": true, "name": name}
	return result.merged(extra)

func apply(target: AnimationPlayer, name: String, replacement: Animation) -> void:
	var library := target.get_animation_library(&"")
	if library == null:
		if replacement == null:
			return
		library = AnimationLibrary.new()
		target.add_animation_library(&"", library)
	if library.has_animation(name):
		library.remove_animation(name)
	if replacement != null:
		library.add_animation(name, replacement)
	elif library.get_animation_list().is_empty():
		target.remove_animation_library(&"")
