@tool
class_name GdApiEditorControls
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

# Overrides are attached to the real editor surface, applied after editor navigation.
# release=true disconnects the override and restores normal interactive navigation.
static var camera_overrides: Dictionary = {}


static func dispatch(operation: String, payload: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _error(ErrorCodes.NOT_SUPPORTED, "editor controls require the editor")
	match operation:
		"undo", "redo":
			return _history(operation)
		"notification":
			var message := str(payload.get("message", ""))
			var severity := str(payload.get("severity", "info"))
			if message == "" or severity not in ["info", "warning", "error"]:
				return _error(
					ErrorCodes.INVALID_PARAM,
					"message is required; severity must be info, warning or error"
				)
			EditorInterface.get_editor_toaster().push_toast(
				message,
				["info", "warning", "error"].find(severity),
				str(payload.get("tooltip", ""))
			)
			return {
				"ok": true,
				"changed": true,
				"undoable": false,
				"message": message,
				"severity": severity
			}
		"inspector/get", "inspector/node", "inspector/resource":
			return _inspector(operation, payload)
		"dock/list", "dock/get", "dock/set", "dock/focus", "dock/distraction_free":
			return _dock(operation, payload)
		"plugins/list", "plugins/enable", "plugins/disable", "plugins/reload":
			return _plugins(operation, payload)
		"settings/get", "settings/set", "settings/list":
			return _settings(operation, payload)
		"camera/get", "camera/set":
			return _camera(operation, payload)
	return _error(ErrorCodes.NOT_FOUND, "unknown editor operation")


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}


static func _history(operation: String) -> Dictionary:
	var manager := EditAction.undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	if manager == null or root == null:
		return _error(ErrorCodes.NOT_FOUND, "no current scene history")
	if manager.is_committing_action():
		return _error(ErrorCodes.CONFLICT, "UndoRedo is currently committing")
	var id := manager.get_object_history_id(root)
	var history := manager.get_history_undo_redo(id)
	if (
		(operation == "undo" and not history.has_undo())
		or (operation == "redo" and not history.has_redo())
	):
		return _error(ErrorCodes.CONFLICT, "current history has no " + operation + " action")
	var action := history.get_current_action_name()
	var succeeded := history.undo() if operation == "undo" else history.redo()
	if not succeeded:
		return _error(ErrorCodes.GODOT_ERROR, "history operation failed")
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"history_id": id,
		"action": action,
		"has_undo": history.has_undo(),
		"has_redo": history.has_redo(),
		"version": history.get_version()
	}


static func _inspector(operation: String, payload: Dictionary) -> Dictionary:
	if operation == "inspector/node":
		var lookup := NodeEditor.find(str(payload.get("node_path", "")))
		if not lookup.ok:
			return lookup
		EditorInterface.inspect_object(lookup.node, str(payload.get("property", "")), true)
	elif operation == "inspector/resource":
		var checked := PathGuard.validate(str(payload.get("path", "")), "read")
		if not checked.ok:
			return checked
		var resource := ResourceLoader.load(checked.path)
		if resource == null:
			return _error(ErrorCodes.NOT_FOUND, "resource does not exist")
		EditorInterface.inspect_object(resource, str(payload.get("property", "")), true)
	var target: Object = EditorInterface.get_inspector().get_edited_object()
	var result := {
		"ok": true,
		"type": target.get_class() if target != null else "",
		"instance_id": target.get_instance_id() if target != null else 0
	}
	if target is Node:
		result["node_path"] = NodeEditor._user_path_for(target)
	elif target is Resource:
		result["path"] = target.resource_path
	if operation != "inspector/get":
		result.merge({"changed": true, "undoable": false})
	return result


static func _collect_docks(node: Node, docks: Array) -> void:
	if node.is_class("EditorDock"):
		docks.append(
			{
				"name": str(node.name),
				"title": str(node.get("title")),
				"visible": (node as Control).is_visible_in_tree()
			}
		)
	for child in node.get_children():
		_collect_docks(child, docks)


static func _find_dock(node: Node, dock_name: String) -> Node:
	if node.is_class("EditorDock") and (
		str(node.name) == dock_name or str(node.get("title")) == dock_name
	):
		return node
	for index in node.get_child_count():
		var found := _find_dock(node.get_child(index), dock_name)
		if found != null:
			return found
	return null


static func _dock(operation: String, payload: Dictionary) -> Dictionary:
	if operation == "dock/distraction_free":
		if not payload.has("enabled") or not payload.enabled is bool:
			return _error(ErrorCodes.INVALID_PARAM, "enabled must be a bool")
		EditorInterface.set_distraction_free_mode(payload.enabled)
		var enabled := EditorInterface.is_distraction_free_mode_enabled()
		if enabled != payload.enabled:
			return _error(ErrorCodes.GODOT_ERROR, "distraction-free read-back failed")
		return {"ok": true, "changed": true, "undoable": false, "enabled": enabled}
	if operation == "dock/list":
		var docks: Array = []
		_collect_docks(EditorInterface.get_base_control(), docks)
		return {
			"ok": true,
			"docks": docks,
			"distraction_free": EditorInterface.is_distraction_free_mode_enabled()
		}
	var name := str(payload.get("name", ""))
	if name == "":
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	var dock: Variant = _find_dock(EditorInterface.get_base_control(), name)
	if dock == null:
		return _error(ErrorCodes.NOT_FOUND, "dock does not exist: " + name)
	var was_visible: bool = dock.is_visible_in_tree()
	if operation == "dock/set":
		if not payload.has("visible") or not payload.visible is bool:
			return _error(ErrorCodes.INVALID_PARAM, "visible must be a bool")
		if payload.visible:
			dock.make_visible()
		else:
			dock.close()
	elif operation == "dock/focus":
		var path := str(payload.get("path", ""))
		if name == "FileSystem" and path != "":
			var checked := PathGuard.validate(path, "read")
			if not checked.ok:
				return checked
			if (
				not FileAccess.file_exists(checked.path)
				and not DirAccess.dir_exists_absolute(checked.path)
			):
				return _error(ErrorCodes.NOT_FOUND, "filesystem target does not exist")
			EditorInterface.get_file_system_dock().navigate_to_path(checked.path)
		elif name == "Script" and path != "":
			var checked := PathGuard.validate(path, "read")
			if not checked.ok:
				return checked
			var script := ResourceLoader.load(checked.path)
			if not script is Script:
				return _error(ErrorCodes.INVALID_PARAM, "script focus requires a Script resource")
			if bool(
				EditorInterface.get_editor_settings().get_setting(
					"text_editor/external/use_external_editor"
				)
			):
				return _error(
					ErrorCodes.PERMISSION_DENIED,
					"external script editor execution is not permitted"
				)
			EditorInterface.edit_script(script, maxi(int(payload.get("line", 1)), 1), 1, true)
		dock.make_visible()
	var result := {
		"ok": true,
		"name": name,
		"visible": dock.is_visible_in_tree(),
		"closed": not dock.is_visible_in_tree()
	}
	if operation != "dock/get":
		result.merge({"changed": was_visible != dock.is_visible_in_tree(), "undoable": false})
	return result


static func _plugin_configs(directory: String, entries: Array) -> void:
	for child in DirAccess.get_directories_at(directory):
		if child.begins_with("."):
			continue
		var folder := directory.path_join(child)
		var cfg_path := folder.path_join("plugin.cfg")
		if FileAccess.file_exists(cfg_path):
			var config := ConfigFile.new()
			if config.load(cfg_path) == OK:
				var key := folder.trim_prefix("res://addons/")
				entries.append(
					{
						"plugin": key,
						"name": str(config.get_value("plugin", "name", key)),
						"script":
						(
							folder
							. path_join(str(config.get_value("plugin", "script", "")))
							. simplify_path()
						),
						"enabled": EditorInterface.is_plugin_enabled(key)
					}
				)
		else:
			_plugin_configs(folder, entries)


static func _plugins(operation: String, payload: Dictionary) -> Dictionary:
	var entries: Array = []
	_plugin_configs("res://addons", entries)
	if operation == "plugins/list":
		return {"ok": true, "plugins": entries}
	var key := str(payload.get("plugin", ""))
	var selected: Dictionary = {}
	for entry in entries:
		if entry.plugin == key:
			selected = entry
			break
	if selected.is_empty():
		return _error(ErrorCodes.NOT_FOUND, "plugin.cfg not found for plugin")
	if key == "gdapi" or str(selected.script).begins_with("res://addons/gdapi/"):
		return _error(
			ErrorCodes.PERMISSION_DENIED,
			"the gdapi provider cannot be enabled, disabled or reloaded through its own API"
		)
	var before := EditorInterface.is_plugin_enabled(key)
	if operation == "plugins/reload":
		if not before:
			return _error(ErrorCodes.CONFLICT, "plugin must be enabled before reload")
		EditorInterface.set_plugin_enabled(key, false)
		if EditorInterface.is_plugin_enabled(key):
			return _error(ErrorCodes.GODOT_ERROR, "plugin failed to disable")
		var script: Resource = ResourceLoader.load(selected.script)
		if not script is Script or script.reload(true) != OK:
			EditorInterface.set_plugin_enabled(key, before)
			return _error(
				ErrorCodes.GODOT_ERROR, "plugin script reload failed; restored enabled state"
			)
	var expected := operation != "plugins/disable"
	EditorInterface.set_plugin_enabled(key, expected)
	if EditorInterface.is_plugin_enabled(key) != expected:
		EditorInterface.set_plugin_enabled(key, before)
		return _error(
			ErrorCodes.GODOT_ERROR, "plugin state read-back failed; restored previous state"
		)
	return {
		"ok": true,
		"changed": operation == "plugins/reload" or before != expected,
		"undoable": false,
		"plugin": key,
		"enabled": expected,
		"reloaded": operation == "plugins/reload"
	}


static func _settings(operation: String, payload: Dictionary) -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	if operation == "settings/list":
		var prefix := str(payload.get("prefix", ""))
		var items: Array = []
		for info in settings.get_property_list():
			var name := str(info.name)
			if name.begins_with(prefix) and settings.has_setting(name):
				items.append(
					{
						"name": name,
						"type": int(info.type),
						"value": Codec.from_variant(settings.get_setting(name))
					}
				)
		return {"ok": true, "settings": items}
	var name := str(payload.get("name", ""))
	if not settings.has_setting(name):
		return _error(ErrorCodes.NOT_FOUND, "editor setting does not exist")
	var previous: Variant = settings.get_setting(name)
	if operation == "settings/get":
		return {"ok": true, "name": name, "value": Codec.from_variant(previous)}
	# External executable, credential and network fields are not an API execution channel.
	if (
		name.begins_with("text_editor/external/")
		or name.begins_with("network/")
		or name.begins_with("export/")
		or name.begins_with("filesystem/import/")
		or name.begins_with("_editors")
	):
		return _error(ErrorCodes.PERMISSION_DENIED, "dangerous editor setting is protected")
	var decoded := Codec.decode(payload.get("value"))
	if not decoded.ok:
		return _error(ErrorCodes.INVALID_PARAM, decoded.error)
	var value: Variant = decoded.value
	if typeof(value) != typeof(previous):
		if previous is float and (value is int or value is float):
			value = float(value)
		else:
			return _error(ErrorCodes.INVALID_PARAM, "setting value must match the existing type")
	if typeof(value) in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL]:
		return _error(ErrorCodes.PERMISSION_DENIED, "object settings are protected")
	var disk_path := settings.resource_path
	if disk_path == "":
		return _error(ErrorCodes.GODOT_ERROR, "EditorSettings has no persistence path")
	var existed := FileAccess.file_exists(disk_path)
	var backup := FileAccess.get_file_as_bytes(disk_path) if existed else PackedByteArray()
	settings.set_setting(name, value)
	var saved := ResourceSaver.save(settings, disk_path)
	var persisted: Resource = (
		ResourceLoader.load(disk_path, "EditorSettings", ResourceLoader.CACHE_MODE_IGNORE)
		if saved == OK
		else null
	)
	if (
		saved != OK
		or settings.get_setting(name) != value
		or persisted == null
		or persisted.get(name) != value
	):
		settings.set_setting(name, previous)
		if existed:
			var file := FileAccess.open(disk_path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(backup)
				file.close()
		else:
			DirAccess.remove_absolute(disk_path)
		return _error(ErrorCodes.GODOT_ERROR, "editor settings save/read-back failed; rolled back")
	return {
		"ok": true,
		"changed": previous != value,
		"undoable": false,
		"saved": true,
		"name": name,
		"value": Codec.from_variant(value),
		"settings_path": disk_path
	}


static func _viewport(payload: Dictionary) -> Dictionary:
	var dimension := str(payload.get("dimension", "2d")).to_lower()
	var index := int(payload.get("index", 0))
	if dimension not in ["2d", "3d"] or index < 0 or index > 3:
		return _error(ErrorCodes.INVALID_PARAM, "dimension must be 2d or 3d; index must be 0..3")
	var viewport: SubViewport = (
		EditorInterface.get_editor_viewport_2d()
		if dimension == "2d"
		else EditorInterface.get_editor_viewport_3d(index)
	)
	if viewport == null:
		return _error(ErrorCodes.NOT_FOUND, "editor viewport unavailable")
	return {
		"ok": true,
		"viewport": viewport,
		"dimension": dimension,
		"index": index,
		"key": dimension + ":" + str(index)
	}


static func _apply_cameras() -> void:
	for key in camera_overrides.keys():
		var entry: Dictionary = camera_overrides[key]
		var viewport: SubViewport = entry.viewport.get_ref()
		if viewport == null:
			camera_overrides.erase(key)
			continue
		if entry.dimension == "2d":
			viewport.global_canvas_transform = entry.transform
		else:
			var camera := viewport.get_camera_3d()
			if camera != null:
				camera.global_transform = entry.transform
				if entry.has("fov"):
					camera.fov = entry.fov


static func _camera(operation: String, payload: Dictionary) -> Dictionary:
	var selected := _viewport(payload)
	if not selected.ok:
		return selected
	var viewport: SubViewport = selected.viewport
	var camera := viewport.get_camera_3d() if selected.dimension == "3d" else null
	if selected.dimension == "3d" and camera == null:
		return _error(ErrorCodes.NOT_FOUND, "3D editor camera unavailable")
	if operation == "camera/set":
		if bool(payload.get("release", false)):
			if camera_overrides.has(selected.key):
				var original: Dictionary = camera_overrides[selected.key]
				if selected.dimension == "2d":
					viewport.global_canvas_transform = original.previous
				else:
					camera.global_transform = original.previous
					camera.fov = original.previous_fov
			camera_overrides.erase(selected.key)
			if (
				camera_overrides.is_empty()
				and RenderingServer.frame_pre_draw.is_connected(_apply_cameras)
			):
				RenderingServer.frame_pre_draw.disconnect(_apply_cameras)
		else:
			var decoded := Codec.decode(payload.get("transform"))
			if not decoded.ok:
				return _error(ErrorCodes.INVALID_PARAM, decoded.error)
			var expected := TYPE_TRANSFORM2D if selected.dimension == "2d" else TYPE_TRANSFORM3D
			if typeof(decoded.value) != expected:
				return _error(ErrorCodes.INVALID_PARAM, "transform must match viewport dimension")
			var transform: Variant = decoded.value
			if (
				not transform.is_finite()
				or is_zero_approx(
					(
						transform.determinant()
						if selected.dimension == "2d"
						else transform.basis.determinant()
					)
				)
			):
				return _error(ErrorCodes.INVALID_PARAM, "transform must be finite and invertible")
			var previous: Variant = (
				viewport.global_canvas_transform if selected.dimension == "2d" else camera.global_transform
			)
			var entry := {
				"viewport": weakref(viewport),
				"dimension": selected.dimension,
				"transform": transform,
				"previous": previous,
				"previous_fov": camera.fov if camera != null else 0.0
			}
			if camera_overrides.has(selected.key):
				entry.previous = camera_overrides[selected.key].previous
				entry.previous_fov = camera_overrides[selected.key].previous_fov
			if payload.has("fov"):
				if (
					selected.dimension != "3d"
					or not (payload.fov is float or payload.fov is int)
					or float(payload.fov) < 1.0
					or float(payload.fov) > 179.0
				):
					return _error(ErrorCodes.INVALID_PARAM, "fov requires 3d and range 1..179")
				entry["fov"] = float(payload.fov)
			camera_overrides[selected.key] = entry
			if not RenderingServer.frame_pre_draw.is_connected(_apply_cameras):
				RenderingServer.frame_pre_draw.connect(_apply_cameras)
	_apply_cameras()
	var actual: Variant = (
		viewport.global_canvas_transform if selected.dimension == "2d" else camera.global_transform
	)
	var result := {
		"ok": true,
		"dimension": selected.dimension,
		"index": selected.index,
		"transform": Codec.from_variant(actual),
		"override": camera_overrides.has(selected.key),
		"viewport_size": [viewport.size.x, viewport.size.y]
	}
	if camera != null:
		result["fov"] = camera.fov
	if operation == "camera/set":
		result.merge({"changed": true, "undoable": false})
	return result


static func screenshot(payload: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _error(ErrorCodes.NOT_SUPPORTED, "editor screenshot requires editor")
	if DisplayServer.get_name() == "headless":
		return _error(
			ErrorCodes.NOT_SUPPORTED, "viewport screenshots require a real GUI rendering surface"
		)
	var selected := _viewport(payload)
	if not selected.ok:
		return selected
	var checked := PathGuard.validate(str(payload.get("path", "")), "write")
	if not checked.ok:
		return checked
	if checked.path.get_extension().to_lower() != "png":
		return _error(ErrorCodes.INVALID_PARAM, "screenshot path must end in .png")
	var width := int(payload.get("width", 0))
	var height := int(payload.get("height", 0))
	if width < 0 or height < 0 or width > 8192 or height > 8192 or (width == 0) != (height == 0):
		return _error(
			ErrorCodes.INVALID_PARAM, "width and height must both be omitted or be 1..8192"
		)
	EditorInterface.set_main_screen_editor("2D" if selected.dimension == "2d" else "3D")
	await (Engine.get_main_loop() as SceneTree).process_frame
	await RenderingServer.frame_post_draw
	var viewport: SubViewport = selected.viewport
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return _error(ErrorCodes.GODOT_ERROR, "editor viewport returned an empty image")
	image.convert(Image.FORMAT_RGBA8)
	var source_size := [image.get_width(), image.get_height()]
	if width > 0:
		image.resize(width, height, Image.INTERPOLATE_LANCZOS)
	var existed := FileAccess.file_exists(checked.path)
	var backup := FileAccess.get_file_as_bytes(checked.path) if existed else PackedByteArray()
	var error := image.save_png(checked.path)
	var reread := Image.new()
	var loaded := reread.load(checked.path) if error == OK else error
	if (
		error != OK
		or loaded != OK
		or reread.get_size() != image.get_size()
		or reread.get_data() != image.get_data()
	):
		if existed:
			var file := FileAccess.open(checked.path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(backup)
				file.close()
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(checked.path))
		return _error(ErrorCodes.GODOT_ERROR, "PNG save/read-back failed; restored previous file")
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"path": checked.path,
		"dimension": selected.dimension,
		"index": selected.index,
		"width": image.get_width(),
		"height": image.get_height(),
		"source_size": source_size,
		"bytes": FileAccess.get_file_as_bytes(checked.path).size(),
		"sha256": FileAccess.get_sha256(checked.path)
	}
