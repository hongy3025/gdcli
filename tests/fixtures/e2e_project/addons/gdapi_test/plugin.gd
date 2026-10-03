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
	var diagnostics := {}
	if root != null and typeof(body) == TYPE_DICTIONARY:
		var manager := get_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
		ok = history.undo() if body.get("action") == "undo" else history.redo()
		if not ok:
			diagnostics = {
				"scene_path": root.scene_file_path,
				"scene_name": String(root.name),
				"can_undo": history.can_undo(),
				"can_redo": history.can_redo(),
				"history_count": history.get_history_count(),
				"action": body.get("action"),
			}
	else:
		diagnostics = {"scene_path": "", "scene_name": "", "action": body.get("action")}
	var file := FileAccess.open(RESULT_TEMP, FileAccess.WRITE)
	file.store_string(JSON.stringify({"ok": ok, "diagnostics": diagnostics}))
	file.close()
	if FileAccess.file_exists(RESULT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT))
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(RESULT_TEMP), ProjectSettings.globalize_path(RESULT)
	)
