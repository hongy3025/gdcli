@tool
extends EditorPlugin

const COMMAND := "res://.godot/gdapi-test-command.json"
const RESULT := "res://.godot/gdapi-test-result.json"
const RESULT_TEMP := "res://.godot/gdapi-test-result.tmp"
const EDITOR_SLEEP_USEC := 2000
const EDITOR_SLEEP_SETTINGS := [
	"interface/editor/timers/low_processor_mode_sleep_usec",
	"interface/editor/timers/unfocused_low_processor_mode_sleep_usec",
]

## 最近一次已执行的请求：harness 重投同一 request_id 时只重发结果，不重复执行 undo/redo。
var _last_request_id := ""
var _last_result := ""
var _original_sleep_settings: Dictionary = {}
var _original_os_sleep_usec: int


func _enter_tree() -> void:
	# RPCs and undo/redo are frame-gated. Avoid the editor's 100ms background
	# throttle in this test-only plugin, but retain a positive sleep (no busy loop).
	var settings := EditorInterface.get_editor_settings()
	for key in EDITOR_SLEEP_SETTINGS:
		_original_sleep_settings[key] = settings.get_setting(key)
		settings.set_setting(key, EDITOR_SLEEP_USEC)
	_original_os_sleep_usec = OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode_sleep_usec = EDITOR_SLEEP_USEC


func _exit_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	for key in _original_sleep_settings:
		settings.set_setting(key, _original_sleep_settings[key])
	OS.low_processor_usage_mode_sleep_usec = _original_os_sleep_usec


func _process(_delta: float) -> void:
	if not FileAccess.file_exists(COMMAND):
		return
	var body = JSON.parse_string(FileAccess.get_file_as_string(COMMAND))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COMMAND))
	if typeof(body) != TYPE_DICTIONARY:
		return
	var request_id := String(body.get("request_id", ""))
	if not request_id.is_empty() and request_id == _last_request_id and not _last_result.is_empty():
		# 命令可能在编辑器读取前被删除（上一帧的 remove 竞态），harness 会重投同一 id。
		_publish(_last_result)
		return
	var root := EditorInterface.get_edited_scene_root()
	var ok := false
	var diagnostics := {}
	if root != null:
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
	_last_request_id = request_id
	_last_result = JSON.stringify({"ok": ok, "diagnostics": diagnostics, "request_id": request_id})
	_publish(_last_result)


func _publish(payload: String) -> void:
	var file := FileAccess.open(RESULT_TEMP, FileAccess.WRITE)
	file.store_string(payload)
	file.close()
	if FileAccess.file_exists(RESULT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT))
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(RESULT_TEMP), ProjectSettings.globalize_path(RESULT)
	)
