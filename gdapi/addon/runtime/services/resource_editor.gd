## M2 资源编辑服务
##
## 提供 Resource 类的 info / deps / 搜索 / reimport / create / assign / move / delete,
## 通过 ClassDB.is_parent_class(class, "Resource") 限制可实例化的资源类型。

@tool
class_name GdApiResourceEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")


## Generic property access uses the actual property list, not arbitrary Object.set().
static func get_property(path: Variant, property: Variant) -> Dictionary:
	var target := _property_target(path, property, "read")
	if not target.ok:
		return target
	return {
		"ok": true,
		"path": target.path,
		"property": property,
		"value": VariantCodec.from_variant(target.resource.get(property)),
		"type": type_string(int(target.spec.type)),
		"usage": int(target.spec.usage),
		"writable": _writable_property(target.resource, target.spec),
		"undoable": false,
	}


static func set_property(path: Variant, property: Variant, value: Variant) -> Dictionary:
	var target := _property_target(path, property, "write")
	if not target.ok:
		return target
	if not _writable_property(target.resource, target.spec):
		return _failure(ErrorCodes.PERMISSION_DENIED, "resource property is protected or read-only")
	var decoded := decode_property(value, target.spec)
	if not decoded.ok:
		return decoded
	var resource: Resource = target.resource
	var previous: Variant = resource.get(property)
	resource.set(property, decoded.value)
	if not _equivalent(resource.get(property), decoded.value):
		resource.set(property, previous)
		return _failure(ErrorCodes.GODOT_ERROR, "resource rejected the property value")
	var result := save_verified(resource, target.path, "resource/set")
	if not result.ok:
		resource.set(property, previous)
		return result
	result["property"] = property
	result["value"] = VariantCodec.from_variant(resource.get(property))
	result["changed"] = not _equivalent(previous, resource.get(property))
	return result


static func _property_target(path: Variant, property: Variant, mode: String) -> Dictionary:
	if typeof(path) != TYPE_STRING or typeof(property) != TYPE_STRING:
		return _failure(ErrorCodes.INVALID_PARAM, "path and property must be strings")
	if String(property).is_empty():
		return _failure(ErrorCodes.MISSING_PARAM, "property is required")
	var checked := PathGuard.validate(path, mode)
	if not checked.ok:
		return checked
	if mode == "write" and not checked.path.get_extension() in ["tres", "res"]:
		return _failure(ErrorCodes.INVALID_PATH, "resource/set requires a .tres or .res resource")
	if not ResourceLoader.exists(checked.path):
		return _failure(ErrorCodes.NOT_FOUND, "resource not found: " + checked.path)
	var resource := ResourceLoader.load(
		checked.path,
		"",
		(
			ResourceLoader.CACHE_MODE_REPLACE_DEEP
			if mode == "write"
			else ResourceLoader.CACHE_MODE_IGNORE_DEEP
		)
	)
	if resource == null:
		return _failure(ErrorCodes.GODOT_ERROR, "failed to load resource")
	for spec in resource.get_property_list():
		if String(spec.name) == property:
			return {"ok": true, "resource": resource, "spec": spec, "path": checked.path}
	return _failure(ErrorCodes.NOT_FOUND, "resource property not found: " + String(property))


static func _writable_property(resource: Resource, spec: Dictionary) -> bool:
	var name := String(spec.name)
	return (
		not resource is Script
		and not resource is Shader
		and name not in ["script", "source_code", "code", "resource_path"]
		and not name.begins_with("_")
		and bool(int(spec.usage) & PROPERTY_USAGE_STORAGE)
		and not bool(int(spec.usage) & PROPERTY_USAGE_READ_ONLY)
	)


static func decode_property(value: Variant, spec: Dictionary) -> Dictionary:
	var decoded := VariantCodec.decode(value)
	if not decoded.ok:
		return _failure(ErrorCodes.INVALID_PARAM, decoded.error)
	var expected := int(spec.type)
	var actual := typeof(decoded.value)
	if expected == TYPE_INT and actual == TYPE_FLOAT:
		var number := float(decoded.value)
		if not is_finite(number) or number != floor(number):
			return _failure(ErrorCodes.INVALID_PARAM, "property requires a finite integer")
		decoded.value = int(number)
	elif expected == TYPE_FLOAT and actual == TYPE_INT:
		decoded.value = float(decoded.value)
	elif expected == TYPE_STRING_NAME and actual == TYPE_STRING:
		decoded.value = StringName(decoded.value)
	elif expected != TYPE_NIL and actual != expected:
		if not (expected == TYPE_OBJECT and decoded.value == null):
			return _failure(ErrorCodes.INVALID_PARAM, "property requires " + type_string(expected))
	if expected == TYPE_OBJECT and decoded.value != null:
		if not decoded.value is Resource:
			return _failure(ErrorCodes.INVALID_PARAM, "object properties require a Resource")
		if not _resource_matches_spec(decoded.value, spec):
			return _failure(ErrorCodes.INVALID_PARAM, "resource class does not match property")
	return decoded


static func _resource_matches_spec(resource: Resource, spec: Dictionary) -> bool:
	var classes := String(spec.get("hint_string", "")).split(",", false)
	if int(spec.get("hint", 0)) != PROPERTY_HINT_RESOURCE_TYPE:
		classes = PackedStringArray()
	var declared := String(spec.get("class_name", ""))
	if classes.is_empty() and not declared.is_empty():
		classes.append(declared)
	for class_type in classes:
		var expected := class_type.strip_edges()
		if resource.is_class(expected):
			return true
		# Object.is_class only knows native classes; custom Resource types are
		# declared by their scripts, including inherited global script classes.
		var script: Script = resource.get_script()
		while script != null:
			if script.get_global_name() == expected or script.resource_path == expected:
				return true
			script = script.get_base_script()
	return classes.is_empty()


## One save strategy for resource, material, shader-material and Theme mutations.
## Capture bytes before writing and compare the actual uncached disk resource.
static func save_verified(resource: Resource, path: String, route: String) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return checked
	path = checked.path
	var existed := FileAccess.file_exists(path)
	var before := PackedByteArray()
	if existed:
		var probe := FileAccess.open(path, FileAccess.READ_WRITE)
		if probe == null:
			return _save_failure(
				route, path, "resource file is not writable", ErrorCodes.PERMISSION_DENIED
			)
		before = probe.get_buffer(probe.get_length())
		probe.close()
	var previous_path := resource.resource_path
	var uid_path := path + ".uid"
	var uid_existed := FileAccess.file_exists(uid_path)
	var uid_before := FileAccess.get_file_as_bytes(uid_path) if uid_existed else PackedByteArray()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path).get_base_dir()
	)
	if mkdir_error != OK:
		return _save_failure(route, path, "failed to create resource directory")
	var save_error := ResourceSaver.save(resource, path)
	var persisted: Resource = null
	if save_error == OK:
		persisted = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if save_error != OK or persisted == null or not _equivalent(resource, persisted):
		var restored := _restore_file(path, existed, before)
		restored = _restore_file(uid_path, uid_existed, uid_before) and restored
		resource.resource_path = previous_path
		var message := "resource save/read-back failed: " + str(save_error)
		if not restored:
			message += "; disk rollback failed"
		return _save_failure(route, path, message)
	# Replace any pre-overwrite cached object only after disk read-back succeeds.
	# Default-mode consumers (resource/assign, info and other editor callers) then
	# resolve the persisted replacement rather than a stale cached instance.
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE_DEEP)
	AuditLog.record(route, "file", {"path": path}, true)
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": path}


static func _restore_file(path: String, existed: bool, bytes: PackedByteArray) -> bool:
	if not existed:
		return not FileAccess.file_exists(path) or DirAccess.remove_absolute(path) == OK
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_file_as_bytes(path) == bytes
	file.store_buffer(bytes)
	file.close()
	return FileAccess.get_file_as_bytes(path) == bytes


static func _equivalent(a: Variant, b: Variant, visited: Array = []) -> bool:
	if a is Resource and b is Resource:
		if a.get_class() != b.get_class():
			return false
		var pair := [a.get_instance_id(), b.get_instance_id()]
		if pair in visited:
			return true
		visited.append(pair)
		for spec in a.get_property_list():
			if int(spec.usage) & PROPERTY_USAGE_STORAGE and spec.name != "resource_path":
				if not _equivalent(a.get(spec.name), b.get(spec.name), visited):
					return false
		return true
	if typeof(a) == TYPE_FLOAT and typeof(b) == TYPE_FLOAT:
		return is_equal_approx(a, b)
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for index in a.size():
			if not _equivalent(a[index], b[index], visited):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _equivalent(a[key], b[key], visited):
				return false
		return true
	if a is Color and b is Color:
		return a.is_equal_approx(b)
	return a == b


static func _save_failure(
	route: String, path: String, message: String, code: String = ErrorCodes.GODOT_ERROR
) -> Dictionary:
	AuditLog.record(route, "file", {"path": path}, false, code)
	return _failure(code, message)


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message, "changed": false, "undoable": false}


class PreviewResult:
	extends RefCounted
	var complete := false
	var texture: Texture2D

	func receive(
		_path: String, preview_texture: Texture2D, _small: Texture2D, _data: Variant
	) -> void:
		texture = preview_texture
		complete = true


## Godot disables the EditorResourcePreview work queue under a headless display server.
## Its built-in Gradient generator renders through GradientTexture1D, so keep that real
## generator output available in headless editor runs instead of waiting for a callback
## that the editor will never dispatch.
static func _headless_gradient_preview(gradient: Gradient) -> Image:
	var texture := GradientTexture1D.new()
	var settings := EditorInterface.get_editor_settings()
	var thumbnail_size := int(settings.get_setting("filesystem/file_dialog/thumbnail_size"))
	var editor_scale := EditorInterface.get_editor_scale()
	texture.width = maxi(1, int(thumbnail_size * editor_scale * 4.0 * editor_scale))
	texture.gradient = gradient
	return texture.get_image()


static func preview(
	path: Variant, width: Variant = 0, height: Variant = 0, deadline_ms: Variant = 5000
) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _failure(ErrorCodes.INVALID_PARAM, "path must be a string")
	for size in [width, height, deadline_ms]:
		if (
			not (typeof(size) in [TYPE_INT, TYPE_FLOAT])
			or not is_finite(float(size))
			or float(size) != floor(float(size))
		):
			return _failure(
				ErrorCodes.INVALID_PARAM, "preview dimensions/deadline must be integers"
			)
	if (
		width < 0
		or height < 0
		or width > 4096
		or height > 4096
		or deadline_ms < 1
		or deadline_ms > 30000
	):
		return _failure(
			ErrorCodes.INVALID_PARAM, "dimensions must be 0-4096; deadline_ms must be 1-30000"
		)
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return checked
	if not ResourceLoader.exists(checked.path):
		return _failure(ErrorCodes.NOT_FOUND, "resource not found")
	var resource := ResourceLoader.load(checked.path)
	if resource == null:
		return _failure(ErrorCodes.GODOT_ERROR, "failed to load resource")
	var image: Image
	var source := "texture"
	if resource is Texture2D:
		image = resource.get_image()
	elif Engine.is_editor_hint():
		var generator := EditorInterface.get_resource_previewer()
		if generator == null:
			return _failure(
				ErrorCodes.NOT_SUPPORTED,
				"EditorResourcePreview unavailable for " + resource.get_class()
			)
		if DisplayServer.get_name() == "headless" and resource is Gradient:
			image = _headless_gradient_preview(resource)
			source = "editor_resource_preview"
		else:
			# EditorResourcePreview retains only the receiver's ObjectID; keep the
			# receiver strongly referenced locally until its deferred callback arrives.
			var pending := PreviewResult.new()
			var deadline := Time.get_ticks_msec() + int(deadline_ms)
			generator.queue_edited_resource_preview(resource, pending, &"receive", null)
			var tree := EditorInterface.get_base_control().get_tree()
			while not pending.complete and Time.get_ticks_msec() < deadline:
				await tree.create_timer(0.02).timeout
			if not pending.complete:
				return _failure(ErrorCodes.TIMEOUT, "resource preview generation exceeded deadline")
			if pending.texture == null:
				return _failure(
					ErrorCodes.NOT_SUPPORTED,
					"no preview generator for resource class " + resource.get_class()
				)
			image = pending.texture.get_image()
			source = "editor_resource_preview"
	else:
		return _failure(
			ErrorCodes.NOT_SUPPORTED, "non-texture previews require EditorResourcePreview"
		)
	if image == null or image.is_empty():
		return _failure(
			ErrorCodes.GODOT_ERROR,
			"preview generator returned no image for " + resource.get_class()
		)
	if image.is_compressed() and image.decompress() != OK:
		return _failure(ErrorCodes.GODOT_ERROR, "failed to decompress preview image")
	var original_width := image.get_width()
	var original_height := image.get_height()
	var out_width := int(width)
	var out_height := int(height)
	if out_width == 0 and out_height == 0:
		var ratio := minf(1.0, 256.0 / maxf(original_width, original_height))
		out_width = maxi(1, int(round(original_width * ratio)))
		out_height = maxi(1, int(round(original_height * ratio)))
	elif out_width == 0:
		out_width = maxi(1, int(round(float(original_width) * out_height / original_height)))
	elif out_height == 0:
		out_height = maxi(1, int(round(float(original_height) * out_width / original_width)))
	if out_width > 4096 or out_height > 4096:
		return _failure(ErrorCodes.INVALID_PARAM, "aspect-preserving output exceeds 4096 pixels")
	if out_width != original_width or out_height != original_height:
		image.resize(out_width, out_height, Image.INTERPOLATE_NEAREST)
	var png := image.save_png_to_buffer()
	if png.is_empty():
		return _failure(ErrorCodes.GODOT_ERROR, "PNG encoding failed")
	return {
		"ok": true,
		"path": checked.path,
		"class": resource.get_class(),
		"source": source,
		"format": "png",
		"png_base64": Marshalls.raw_to_base64(png),
		"width": image.get_width(),
		"height": image.get_height(),
		"original_width": original_width,
		"original_height": original_height,
		"undoable": false,
	}


## 读取资源元数据
static func info(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ResourceLoader.exists(checked.path):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "resource not found: " + checked.path
		}
	var res: Resource = load(checked.path)
	if res == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "failed to load resource"}
	var uid_str := ""
	var uid_path: String = checked.path + ".uid"
	if FileAccess.file_exists(uid_path):
		uid_str = FileAccess.get_file_as_string(uid_path).strip_edges()
	var props: Dictionary = {}
	for info_obj in res.get_property_list():
		if info_obj.usage & PROPERTY_USAGE_CATEGORY:
			continue
		if info_obj.name.begins_with("_"):
			continue
		if info_obj.usage & PROPERTY_USAGE_STORAGE:
			props[info_obj.name] = VariantCodec.from_variant(res.get(info_obj.name))
	return {
		"ok": true,
		"path": checked.path,
		"uid": uid_str,
		"class": res.get_class(),
		"script": res.get_script().resource_path if res.get_script() != null else "",
		"local_to_scene": res.is_local_to_scene(),
		"properties": props,
		"undoable": false,
	}


## 反向依赖列表 (search inbound references using the editor)
static func deps(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not Engine.is_editor_hint():
		return {
			"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/deps requires editor"
		}
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {
			"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"
		}
	# 简易实现: 用 .get_dependencies 看哪些其它文件依赖于本资源
	var items: Array = []
	if not ResourceLoader.exists(checked.path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "resource not found"}
	var deps_list := ResourceLoader.get_dependencies(checked.path)
	for d in deps_list:
		items.append(d)
	items.sort()
	return {
		"ok": true,
		"path": checked.path,
		"items": items,
		"undoable": false,
	}


## 搜索资源 — 通过 DirAccess 扫描文件系统 (不依赖 EditorFileSystem)
static func search(filter_text: String, offset: int, limit: int) -> Dictionary:
	if limit < 1 or limit > 1000:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "limit must be 1-1000"}
	var all: Array = []
	_scan_dir_for_resources("res://", filter_text.to_lower(), all)
	all.sort()
	var total := all.size()
	return {
		"ok": true,
		"items": all.slice(offset, offset + limit),
		"total": total,
		"offset": offset,
		"limit": limit,
		"undoable": false,
	}


static func _scan_dir_for_resources(dir_path: String, needle: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with(".") or name == "import":
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name) if dir_path.ends_with("/") else dir_path + "/" + name
		if dir.current_is_dir():
			_scan_dir_for_resources(full, needle, out)
		else:
			if needle == "" or full.to_lower().find(needle) >= 0:
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## 重新导入资源
static func reimport(paths: Array) -> Dictionary:
	if not Engine.is_editor_hint():
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "resource/reimport requires editor"
		}
	var validated: Array = []
	for raw in paths:
		var checked := PathGuard.validate(String(raw), "read")
		if not checked.ok:
			return {"ok": false, "code": checked.code, "error": checked.error}
		validated.append(checked.path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {
			"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"
		}
	fs.reimport_files(validated)
	AuditLog.record("resource/reimport", "file", {"paths": validated}, true, "")
	return {"ok": true, "changed": true, "reimported": validated, "undoable": false}


## 创建新资源,要求 type 必须是 Resource 的子类
static func create(path: String, type: String, properties: Dictionary) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Resource"):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "type is not a Resource subclass: " + type
		}
	if not ClassDB.can_instantiate(type):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "type cannot be instantiated: " + type
		}
	var instance: Resource = ClassDB.instantiate(type)
	if instance == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "instantiate failed: " + type}
	for key in properties.keys():
		var decoded := VariantCodec.decode(properties[key])
		if not decoded.ok:
			return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": decoded.error}
		if not (key in instance):
			return {
				"ok": false,
				"code": ErrorCodes.NOT_FOUND,
				"error": "property not found on resource: " + key
			}
		instance.set(key, decoded.value)
	var result := save_verified(instance, checked.path, "resource/create")
	if result.ok:
		result["class"] = type
	return result


## 把资源赋给节点的属性,接 UndoRedo
static func assign(node_path: String, property: String, path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "resource/assign requires editor"
		}
	var NodeEditor := load("res://addons/gdapi/runtime/services/node_editor.gd")
	var lookup: Dictionary = NodeEditor.find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ResourceLoader.exists(checked.path):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "resource not found: " + checked.path
		}
	if not (property in node):
		return {
			"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "node has no property: " + property
		}
	var spec: Dictionary = {}
	for entry in node.get_property_list():
		if String(entry.name) == property:
			spec = entry
			break
	if (
		int(spec.get("type", TYPE_NIL)) != TYPE_OBJECT
		or int(spec.get("hint", 0)) != PROPERTY_HINT_RESOURCE_TYPE
		or bool(int(spec.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY)
	):
		return _failure(
			ErrorCodes.INVALID_PARAM, "property does not accept a Resource: " + property
		)
	var res: Resource = load(checked.path)
	if res == null:
		return _failure(ErrorCodes.GODOT_ERROR, "failed to load resource")
	if not _resource_matches_spec(res, spec):
		return _failure(
			ErrorCodes.INVALID_PARAM, "resource class does not match property: " + property
		)
	var previous: Variant = node.get(property)
	var manager := EditAction.undo_redo()
	if manager == null:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "EditorUndoRedoManager unavailable"
		}
	# A custom setter may reject even a type-compatible resource. Apply and read
	# back before creating an action so a rejection cannot truncate redo history.
	node.set(property, res)
	if node.get(property) != res:
		node.set(property, previous)
		return _failure(ErrorCodes.GODOT_ERROR, "node rejected the resource value")
	manager.create_action("gdcli: assign resource", UndoRedo.MERGE_DISABLE, node)
	manager.add_do_property(node, property, res)
	manager.add_undo_property(node, property, previous)
	manager.commit_action(false)
	return {
		"ok": true,
		"changed": previous != res,
		"undoable": true,
		"node_path": lookup.node_path,
		"property": property,
		"path": checked.path,
	}


## 在编辑器文件系统中移动资源文件
static func move(from_path: String, to_path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {
			"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/move requires editor"
		}
	var from_check := PathGuard.validate(from_path, "read")
	if not from_check.ok:
		return {"ok": false, "code": from_check.code, "error": from_check.error}
	var to_check := PathGuard.validate(to_path, "write")
	if not to_check.ok:
		return {"ok": false, "code": to_check.code, "error": to_check.error}
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {
			"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"
		}
	var err: Error = fs.move_file(from_check.path, to_check.path)
	if err != OK:
		AuditLog.record(
			"resource/move",
			"file",
			{"from": from_check.path, "to": to_check.path},
			false,
			ErrorCodes.GODOT_ERROR
		)
		return {
			"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "move_file failed: " + str(err)
		}
	AuditLog.record(
		"resource/move", "file", {"from": from_check.path, "to": to_check.path}, true, ""
	)
	return {
		"ok": true,
		"changed": true,
		"moved": true,
		"undoable": false,
		"from": from_check.path,
		"to": to_check.path,
	}


## 删除资源文件
static func delete(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "delete")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not FileAccess.file_exists(ProjectSettings.globalize_path(checked.path)):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "resource not found: " + checked.path
		}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	var err: Error = DirAccess.remove_absolute(abs_path)
	if err != OK:
		AuditLog.record(
			"resource/delete", "file", {"path": checked.path}, false, ErrorCodes.GODOT_ERROR
		)
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "remove failed: " + str(err)}
	AuditLog.record("resource/delete", "file", {"path": checked.path}, true, "")
	return {
		"ok": true,
		"changed": true,
		"deleted": true,
		"undoable": false,
		"path": checked.path,
	}
