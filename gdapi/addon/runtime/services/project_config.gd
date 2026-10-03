@tool
class_name GdApiProjectConfig
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PROJECT_FILE := "res://project.godot"
const MAX_LIMIT := 500


static func page(body: Dictionary) -> Dictionary:
	return {
		"offset": maxi(0, int(body.get("offset", 0))),
		"limit": clampi(int(body.get("limit", 100)), 1, MAX_LIMIT)
	}


static func settings(body: Dictionary) -> Array:
	var filter := String(body.get("filter", ""))
	var names: Array = []
	for item in ProjectSettings.get_property_list():
		var name := String(item.get("name", ""))
		if not name.is_empty() and (filter.is_empty() or name.contains(filter)):
			names.append(name)
	names.sort()
	var p := page(body)
	return names.slice(p.offset, mini(names.size(), p.offset + p.limit))


static func setting(name: String) -> Dictionary:
	if not _valid_setting(name):
		return _err(ErrorCodes.PERMISSION_DENIED, "setting is not writable")
	if not ProjectSettings.has_setting(name):
		return _err(ErrorCodes.NOT_FOUND, "setting not found")
	return {"ok": true, "name": name, "value": ProjectSettings.get_setting(name)}


static func set_setting(name: String, value: Variant) -> Dictionary:
	if not _valid_setting(name):
		return _err(ErrorCodes.PERMISSION_DENIED, "setting is not writable")
	var previous = ProjectSettings.get_setting(name) if ProjectSettings.has_setting(name) else null
	ProjectSettings.set_setting(name, value)
	var saved := _write_project_settings(
		func():
			if previous == null:
				ProjectSettings.clear(name)
			else:
				ProjectSettings.set_setting(name, previous)
	)
	if not saved.ok:
		AuditLog.record(
			"project/settings/set", "dangerous", {"name": name}, false, ErrorCodes.GODOT_ERROR
		)
		return saved
	AuditLog.record("project/settings/set", "dangerous", {"name": name}, true)
	return {"ok": true, "name": name, "value": value, "changed": true, "undoable": false}


static func reset(name: String) -> Dictionary:
	if not _valid_setting(name):
		return _err(ErrorCodes.PERMISSION_DENIED, "setting is not writable")
	if not ProjectSettings.has_setting(name):
		return _err(ErrorCodes.NOT_FOUND, "setting not found")
	var previous = ProjectSettings.get_setting(name)
	ProjectSettings.clear(name)
	var saved := _write_project_settings(func(): ProjectSettings.set_setting(name, previous))
	if not saved.ok:
		AuditLog.record(
			"project/settings/reset", "dangerous", {"name": name}, false, ErrorCodes.GODOT_ERROR
		)
		return saved
	AuditLog.record("project/settings/reset", "dangerous", {"name": name}, true)
	return {"ok": true, "name": name, "changed": true, "undoable": false}


static func input_actions(body: Dictionary) -> Array:
	var names := InputMap.get_actions()
	var filter := String(body.get("filter", ""))
	var items: Array = []
	for action in names:
		var name := String(action)
		if filter.is_empty() or name.contains(filter):
			items.append(
				{
					"action": name,
					"deadzone": InputMap.action_get_deadzone(action),
					"events": _events(action)
				}
			)
	items.sort_custom(func(a, b): return a.action < b.action)
	var p := page(body)
	return items.slice(p.offset, mini(items.size(), p.offset + p.limit))


static func add_action(name: String, deadzone: float) -> Dictionary:
	if name.is_empty():
		return _err(ErrorCodes.MISSING_PARAM, "action is required")
	if InputMap.has_action(name):
		return _err(ErrorCodes.CONFLICT, "action already exists")
	InputMap.add_action(name, deadzone)
	_persist_action(name)
	return _save_input(
		name,
		true,
		func():
			InputMap.erase_action(name)
			ProjectSettings.clear("input/" + name)
	)


static func remove_action(name: String) -> Dictionary:
	if not InputMap.has_action(name):
		return _err(ErrorCodes.NOT_FOUND, "action not found")
	var deadzone := InputMap.action_get_deadzone(name)
	var events := InputMap.action_get_events(name)
	InputMap.erase_action(name)
	ProjectSettings.clear("input/" + name)
	return _save_input(
		name,
		true,
		func():
			ProjectSettings.set_setting("input/" + name, {"deadzone": deadzone, "events": events})
			InputMap.add_action(name, deadzone)
			for event in events:
				InputMap.action_add_event(name, event)
	)


static func bind(name: String, event: Dictionary) -> Dictionary:
	if not InputMap.has_action(name):
		return _err(ErrorCodes.NOT_FOUND, "action not found")
	var parsed := _event(event)
	if parsed == null:
		return _err(ErrorCodes.INVALID_PARAM, "unsupported input event")
	InputMap.action_add_event(name, parsed)
	_persist_action(name)
	return _save_input(
		name,
		true,
		func():
			InputMap.action_erase_event(name, parsed)
			_persist_action(name)
	)


static func unbind(name: String, event: Dictionary) -> Dictionary:
	if not InputMap.has_action(name):
		return _err(ErrorCodes.NOT_FOUND, "action not found")
	var parsed := _event(event)
	if parsed == null:
		return _err(ErrorCodes.INVALID_PARAM, "unsupported input event")
	InputMap.action_erase_event(name, parsed)
	_persist_action(name)
	return _save_input(
		name,
		true,
		func():
			InputMap.action_add_event(name, parsed)
			_persist_action(name)
	)


static func autoloads() -> Array:
	var result: Array = []
	for property in ProjectSettings.get_property_list():
		var name := String(property.get("name", ""))
		if name.begins_with("autoload/"):
			var value := String(
				ProjectSettings.get_setting(name) if ProjectSettings.has_setting(name) else ""
			)
			result.append(
				{
					"name": name.trim_prefix("autoload/"),
					"path": value.trim_prefix("*"),
					"singleton": value.begins_with("*")
				}
			)
	result.sort_custom(func(a, b): return a.name < b.name)
	return result


static func add_autoload(name: String, path: String, singleton: bool) -> Dictionary:
	if not _valid_identifier(name):
		return _err(ErrorCodes.INVALID_PARAM, "invalid autoload name")
	var checked := PathGuard.validate(path, "read")
	if (
		not checked.ok
		or not checked.path.begins_with("res://")
		or checked.path.begins_with("res://addons/gdapi/")
	):
		return _err(ErrorCodes.PERMISSION_DENIED, "autoload path is not allowed")
	if not FileAccess.file_exists(checked.path):
		return _err(ErrorCodes.NOT_FOUND, "autoload script not found")
	var key := "autoload/" + name
	if ProjectSettings.has_setting(key):
		return _err(ErrorCodes.CONFLICT, "autoload already exists")
	ProjectSettings.set_setting(key, ("*" if singleton else "") + checked.path)
	return _save_project(key, func(): ProjectSettings.clear(key))


static func remove_autoload(name: String) -> Dictionary:
	var key := "autoload/" + name
	if not ProjectSettings.has_setting(key):
		return _err(ErrorCodes.NOT_FOUND, "autoload not found")
	var previous = ProjectSettings.get_setting(key)
	ProjectSettings.clear(key)
	return _save_project(key, func(): ProjectSettings.set_setting(key, previous))


## 保存项目设置，并确认真的写进了 project.godot。


## Godot 4.7.2 在目标文件不可写时会返回 OK（先写临时文件，rename 失败被吞掉），
## 因此这里比较保存前后的文件摘要：没有变化即视为失败，并回滚内存状态。
static func _write_project_settings(restore: Callable = Callable()) -> Dictionary:
	var before := _project_file_digest()
	var error := ProjectSettings.save()
	if error != OK or _project_file_digest() == before:
		if restore.is_valid():
			restore.call()
		return _err(ErrorCodes.GODOT_ERROR, "project settings were not written to project.godot")
	return {"ok": true}


static func _project_file_digest() -> String:
	if not FileAccess.file_exists(PROJECT_FILE):
		return ""
	return FileAccess.get_sha256(PROJECT_FILE)


## 把 InputMap 的当前状态写回项目设置：只改 InputMap 不会随项目重载保留。
static func _persist_action(name: String) -> void:
	(
		ProjectSettings
		. set_setting(
			"input/" + name,
			{
				"deadzone": InputMap.action_get_deadzone(name),
				"events": InputMap.action_get_events(name),
			}
		)
	)


static func _save_input(name: String, changed: bool, restore: Callable = Callable()) -> Dictionary:
	var saved := _write_project_settings(restore)
	if not saved.ok:
		AuditLog.record(
			"project/input_map", "dangerous", {"action": name}, false, ErrorCodes.GODOT_ERROR
		)
		return saved
	AuditLog.record("project/input_map", "dangerous", {"action": name}, true)
	return {"ok": true, "action": name, "changed": changed, "undoable": false}


static func _save_project(name: String, restore: Callable = Callable()) -> Dictionary:
	var saved := _write_project_settings(restore)
	if not saved.ok:
		AuditLog.record(
			"project/autoload", "dangerous", {"name": name}, false, ErrorCodes.GODOT_ERROR
		)
		return saved
	AuditLog.record("project/autoload", "dangerous", {"name": name}, true)
	return {"ok": true, "name": name.trim_prefix("autoload/"), "changed": true, "undoable": false}


static func _events(action: String) -> Array:
	var result: Array = []
	for event in InputMap.action_get_events(action):
		result.append(_event_dict(event))
	return result


static func _event_dict(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {
			"type": "InputEventKey",
			"keycode": event.keycode,
			"physical_keycode": event.physical_keycode,
			"unicode": event.unicode,
			"modifiers": event.get_modifiers_mask()
		}
	if event is InputEventMouseButton:
		return {
			"type": "InputEventMouseButton",
			"button_index": event.button_index,
			"modifiers": event.get_modifiers_mask()
		}
	if event is InputEventJoypadButton:
		return {"type": "InputEventJoypadButton", "button_index": event.button_index}
	if event is InputEventJoypadMotion:
		return {
			"type": "InputEventJoypadMotion", "axis": event.axis, "axis_value": event.axis_value
		}
	return {"type": event.get_class()}


static func _event(data: Dictionary) -> InputEvent:
	var type := String(data.get("type", ""))
	var event: InputEvent = null
	match type:
		"InputEventKey":
			var key := InputEventKey.new()
			key.keycode = int(data.get("keycode", 0))
			key.physical_keycode = int(data.get("physical_keycode", 0))
			key.unicode = int(data.get("unicode", 0))
			event = key
		"InputEventMouseButton":
			var mouse := InputEventMouseButton.new()
			mouse.button_index = int(data.get("button_index", 0))
			event = mouse
		"InputEventJoypadButton":
			var button := InputEventJoypadButton.new()
			button.button_index = int(data.get("button_index", 0))
			event = button
		"InputEventJoypadMotion":
			var motion := InputEventJoypadMotion.new()
			motion.axis = int(data.get("axis", 0))
			motion.axis_value = float(data.get("axis_value", 0))
			event = motion
	return event


static func _valid_setting(name: String) -> bool:
	return (
		not name.is_empty()
		and not name.begins_with("_gdapi/")
		and not name.begins_with("autoload/")
	)


static func _valid_identifier(name: String) -> bool:
	return name.is_valid_identifier() and not name.begins_with("_")


static func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
