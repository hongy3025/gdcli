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

## Cache completed requests so retries never repeat history operations or suites.
var _last_request_id := ""
var _last_result := ""
var _result_pending := false
var _suite_running := false
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
	if _result_pending:
		_publish_pending_result()
		if _result_pending:
			return
	if _suite_running:
		return
	if not FileAccess.file_exists(COMMAND):
		return
	var body = JSON.parse_string(FileAccess.get_file_as_string(COMMAND))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COMMAND))
	if typeof(body) != TYPE_DICTIONARY:
		return
	var request_id := String(body.get("request_id", ""))
	if not request_id.is_empty() and request_id == _last_request_id and not _last_result.is_empty():
		# Re-publish a completed request without repeating its side effects.
		_publish(_last_result)
		return
	if body.get("action") == "run_suite":
		_suite_running = true
		await _run_suite(body, request_id)
		_suite_running = false
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
	_complete(request_id, {"ok": ok, "diagnostics": diagnostics})


func _run_suite(body: Dictionary, request_id: String) -> void:
	var path := String(body.get("path", ""))
	var suite_script := load(path) as GDScript
	if suite_script == null or not suite_script.can_instantiate():
		_complete(
			request_id,
			{"ok": false, "passed": 0, "failed": 1, "error": "Cannot load suite: " + path}
		)
		return
	# A suite uses the injected tree; it must never create another SceneTree or
	# rely on a Node's editor lifecycle to start running.
	if suite_script.get_instance_base_type() != "RefCounted":
		_complete(
			request_id,
			{"ok": false, "passed": 0, "failed": 1, "error": "Invalid suite base: " + path}
		)
		return
	var suite = suite_script.new()
	if suite == null or not suite.has_method("run"):
		_complete(
			request_id,
			{"ok": false, "passed": 0, "failed": 1, "error": "Suite has no run(tree): " + path}
		)
		return
	var result: Variant = await suite.call("run", get_tree())
	if (
		typeof(result) != TYPE_DICTIONARY
		or typeof(result.get("passed")) != TYPE_INT
		or typeof(result.get("failed")) != TYPE_INT
		or typeof(result.get("ok")) != TYPE_BOOL
	):
		_complete(
			request_id,
			{"ok": false, "passed": 0, "failed": 1, "error": "Invalid suite result: " + path}
		)
		return
	result["ok"] = result.ok and result.passed > 0 and result.failed == 0
	_complete(request_id, result)


func _complete(request_id: String, result: Dictionary) -> void:
	result["request_id"] = request_id
	_last_request_id = request_id
	_last_result = JSON.stringify(result)
	_publish(_last_result)


func _publish(payload: String) -> void:
	var file := FileAccess.open(RESULT_TEMP, FileAccess.WRITE)
	file.store_string(payload)
	file.close()
	_result_pending = true
	_publish_pending_result()


func _publish_pending_result() -> void:
	# Keep the staged result across Windows reader locks; retry publication, not Undo/Redo.
	_result_pending = (
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(RESULT_TEMP), ProjectSettings.globalize_path(RESULT)
		)
		!= OK
	)
