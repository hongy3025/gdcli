@tool
extends EditorPlugin

const COMMAND := "res://.godot/gdapi-test-command.json"
const RESULT := "res://.godot/gdapi-test-result.json"
const RESULT_TEMP := "res://.godot/gdapi-test-result.tmp"


func _process(_delta: float) -> void:
	if not FileAccess.file_exists(COMMAND):
		return
	var body = JSON.parse_string(FileAccess.get_file_as_string(COMMAND))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COMMAND))
	var root := EditorInterface.get_edited_scene_root()
	var ok := false
	if root != null and typeof(body) == TYPE_DICTIONARY:
		var action := String(body.get("action", ""))
		if action == "undo" or action == "redo":
			ok = _perform_undo_redo(action == "redo")
		elif action == "clear_undo":
			ok = _clear_all_undo()
	var file := FileAccess.open(RESULT_TEMP, FileAccess.WRITE)
	file.store_string(JSON.stringify({"ok": ok}))
	file.close()
	if FileAccess.file_exists(RESULT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT))
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(RESULT_TEMP), ProjectSettings.globalize_path(RESULT)
	)


func _clear_all_undo() -> bool:
	var manager := get_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	for node in _collect_nodes(root):
		var history_id := manager.get_object_history_id(node)
		var ur := manager.get_history_undo_redo(history_id)
		if ur != null:
			while ur.has_undo():
				ur.undo()
	return true


func _perform_undo_redo(is_redo: bool) -> bool:
	var manager := get_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	for node in _collect_nodes(root):
		var history_id := manager.get_object_history_id(node)
		var ur := manager.get_history_undo_redo(history_id)
		if ur != null and (ur.has_undo() if not is_redo else ur.has_redo()):
			return ur.undo() if not is_redo else ur.redo()
	return false


func _collect_nodes(from: Node) -> Array:
	var result: Array = [from]
	for child in from.get_children():
		result += _collect_nodes(child)
	return result
