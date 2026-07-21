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

## 读取资源元数据
static func info(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ResourceLoader.exists(checked.path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "resource not found: " + checked.path}
	var res: Resource = load(checked.path)
	if res == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "failed to load resource"}
	var uid := ResourceUID.path_to_id(checked.path)
	var uid_str := ""
	if uid != ResourceUID.INVALID_ID:
		uid_str = str(uid)
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
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/deps requires editor"}
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"}
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

## 搜索资源 — 通过 EditorFileSystem 扫描
static func search(filter_text: String, offset: int, limit: int) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/search requires editor"}
	if limit < 1 or limit > 1000:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "limit must be 1-1000"}
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"}
	var all: Array = []
	var sc := fs.get_scan_completed()
	_collect_search(fs.get_filesystem(), filter_text.to_lower(), all)
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


static func _collect_search(dir: EditorFileSystemDirectory, needle: String, out: Array) -> void:
	if dir == null:
		return
	for i in dir.get_subdir_count():
		_collect_search(dir.get_subdir(i), needle, out)
	for i in dir.get_file_count():
		var info_obj := dir.get_file(i)
		var path := info_obj.resource_path if info_obj != null else ""
		if path != "" and (needle == "" or path.to_lower().find(needle) >= 0):
			out.append(path)


## 重新导入资源
static func reimport(paths: Array) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/reimport requires editor"}
	var validated: Array = []
	for raw in paths:
		var checked := PathGuard.validate(String(raw), "read")
		if not checked.ok:
			return {"ok": false, "code": checked.code, "error": checked.error}
		validated.append(checked.path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"}
	fs.reimport_files(validated)
	AuditLog.record("resource/reimport", "file", {"paths": validated}, true, "")
	return {"ok": true, "changed": true, "reimported": validated, "undoable": false}

## 创建新资源,要求 type 必须是 Resource 的子类
static func create(path: String, type: String, properties: Dictionary, force: bool) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Resource"):
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "type is not a Resource subclass: " + type}
	if not ClassDB.can_instantiate(type):
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "type cannot be instantiated: " + type}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if FileAccess.file_exists(abs_path) and not force:
		AuditLog.record("resource/create", "file", {"path": checked.path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return {"ok": false, "code": ErrorCodes.UNSAFE_OPERATION, "error": "resource/create requires force:true"}
	var instance: Resource = ClassDB.instantiate(type)
	if instance == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "instantiate failed: " + type}
	for key in properties.keys():
		var decoded := VariantCodec.decode(properties[key])
		if not decoded.ok:
			return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": decoded.error}
		if not (key in instance):
			return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "property not found on resource: " + key}
		instance.set(key, decoded.value)
	var err := ResourceSaver.save(instance, checked.path)
	if err != OK:
		AuditLog.record("resource/create", "file", {"path": checked.path}, false, ErrorCodes.GODOT_ERROR)
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "ResourceSaver.save failed: " + str(err)}
	AuditLog.record("resource/create", "file", {"path": checked.path, "type": type, "force": force}, true, "")
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": checked.path, "class": type}

## 把资源赋给节点的属性,接 UndoRedo
static func assign(node_path: String, property: String, path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/assign requires editor"}
	var NodeEditor := load("res://addons/gdapi/runtime/services/node_editor.gd")
	var lookup: Dictionary = NodeEditor.find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ResourceLoader.exists(checked.path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "resource not found: " + checked.path}
	if not (property in node):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "node has no property: " + property}
	var res: Resource = load(checked.path)
	var previous: Variant = node.get(property)
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	manager.create_action("gdcli: assign resource")
	manager.add_do_method(node, "set", property, res)
	manager.add_undo_method(node, "set", property, previous)
	manager.commit_action()
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": lookup.node_path,
		"property": property,
		"path": checked.path,
	}

## 在编辑器文件系统中移动资源文件
static func move(from_path: String, to_path: String, force: bool) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "resource/move requires editor"}
	var from_check := PathGuard.validate(from_path, "read")
	if not from_check.ok:
		return {"ok": false, "code": from_check.code, "error": from_check.error}
	var to_check := PathGuard.validate(to_path, "write")
	if not to_check.ok:
		return {"ok": false, "code": to_check.code, "error": to_check.error}
	if FileAccess.file_exists(ProjectSettings.globalize_path(to_check.path)) and not force:
		AuditLog.record("resource/move", "file", {"from": from_check.path, "to": to_check.path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return {"ok": false, "code": ErrorCodes.UNSAFE_OPERATION, "error": "resource/move requires force:true"}
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorFileSystem unavailable"}
	var err := fs.move_file(from_check.path, to_check.path)
	if err != OK:
		AuditLog.record("resource/move", "file", {"from": from_check.path, "to": to_check.path}, false, ErrorCodes.GODOT_ERROR)
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "move_file failed: " + str(err)}
	AuditLog.record("resource/move", "file", {"from": from_check.path, "to": to_check.path, "force": force}, true, "")
	return {
		"ok": true,
		"changed": true,
		"moved": true,
		"undoable": false,
		"from": from_check.path,
		"to": to_check.path,
	}

## 删除资源: 引用计数由人工搜索确定;若存在 inbound 引用需要 force
static func delete(path: String, force: bool) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not FileAccess.file_exists(ProjectSettings.globalize_path(checked.path)):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "resource not found: " + checked.path}
	if not force:
		AuditLog.record("resource/delete", "file", {"path": checked.path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return {"ok": false, "code": ErrorCodes.UNSAFE_OPERATION, "error": "resource/delete requires force:true"}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		AuditLog.record("resource/delete", "file", {"path": checked.path}, false, ErrorCodes.GODOT_ERROR)
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "remove failed: " + str(err)}
	AuditLog.record("resource/delete", "file", {"path": checked.path, "force": force}, true, "")
	return {
		"ok": true,
		"changed": true,
		"deleted": true,
		"undoable": false,
		"path": checked.path,
	}
