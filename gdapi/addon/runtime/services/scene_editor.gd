## M2 场景编辑服务
##
## 提供当前场景控制、场景打开/保存/关闭、树序列化等只读/写操作的统一入口。
## 渲染端读取使用 EditorInterface,实际持久化依赖 `EditorInterface.save_scene`.
## 所有写操作产生 audit 记录,失败时返回标准 error code.

@tool
class_name GdApiSceneEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")


## 返回当前编辑场景根节点,未打开场景时返回 null
static func current_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()


## 返回当前编辑场景的 res:// 路径,未打开时为空字符串
static func current_path() -> String:
	var root := current_root()
	if root == null:
		return ""
	return root.scene_file_path if root.scene_file_path != "" else ""


## 检查 scene 是否被当前编辑器打开
static func is_open(path: String) -> bool:
	var root := current_root()
	if root == null:
		return false
	return root.scene_file_path == path


## 解析 res:// 路径到磁盘绝对路径,失败返回空字符串
static func resolve(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if not ResourceLoader.exists(checked.path):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "scene does not exist: " + checked.path,
		}
	return {"ok": true, "path": checked.path, "abs_path": abs_path}


## 递归描述节点树为可 JSON 序列化结构
static func describe_tree(node: Node, max_depth: int, depth: int = 0) -> Dictionary:
	var item := {
		"name": node.name,
		"type": node.get_class(),
		"children": [],
	}
	if node.scene_file_path != "":
		item["scene_file_path"] = node.scene_file_path
	if depth < max_depth:
		for child in node.get_children():
			if child.owner == null:
				continue
			item.children.append(describe_tree(child, max_depth, depth + 1))
	return item


## 关闭编辑器中当前打开的场景,如果该场景是当前路径则调用 EditorInterface.
## Godot 4.7 的 EditorInterface 只提供 close_scene()(关闭当前编辑场景),
## 没有按路径关闭任意已打开场景的 API;因此本方法只支持"当前场景"语义,
## 传入的 path 必须等于当前编辑场景,否则返回 not_found。
## @param path 可选;非空表示关闭指定路径场景,必须与当前场景一致
## @return {ok,changed,undoable}
static func close_scene(path: String) -> Dictionary:
	var current := current_path()
	if current == "":
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	if path != "" and current != path:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "scene is not the current scene: " + path,
		}
	EditorInterface.close_scene()
	AuditLog.record("scene/close", "file", {"path": current, "undoable": false}, true, "")
	return {"ok": true, "changed": true, "undoable": false, "path": current}


## 保存当前场景到指定路径或原路径。目标文件存在时直接覆盖。
static func save_scene(path: String) -> Dictionary:
	var original_path := current_path()
	if original_path == "":
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	var explicit := path != ""
	var target := path if explicit else original_path
	var checked := PathGuard.validate(target, "write")
	if not checked.ok:
		AuditLog.record("scene/current/save", "file", {"path": target}, false, checked.code)
		return {"ok": false, "code": checked.code, "error": checked.error}
	target = checked.path
	var save_result: int
	if target == current_path():
		save_result = EditorInterface.save_scene()
	else:
		EditorInterface.save_scene_as(target)
		save_result = OK
	if save_result != OK:
		AuditLog.record(
			"scene/current/save", "file", {"path": target}, false, ErrorCodes.GODOT_ERROR
		)
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "failed to save scene: " + str(save_result),
		}
	AuditLog.record("scene/current/save", "file", {"path": target}, true, "")
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": target}


## 打开 res:// 路径上的场景,通过 EditorInterface.open_scene_from_path.
static func open_scene(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not ResourceLoader.exists(checked.path):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "scene does not exist: " + checked.path,
		}
	EditorInterface.open_scene_from_path(checked.path)
	AuditLog.record("scene/open", "file", {"path": checked.path}, true, "")
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"path": checked.path,
	}


## 返回当前 editor 已打开的全部场景 res:// 路径数组
## 读取 EditorInterface.get_open_scenes(),过滤空路径后按字典序稳定排序,
## 保证同一编辑器状态多次调用返回顺序一致。
static func list_open_scenes() -> Array:
	if not Engine.is_editor_hint():
		return []
	var paths: Array = []
	for path in EditorInterface.get_open_scenes():
		if path != "":
			paths.append(path)
	paths.sort()
	return paths


static func instantiate_scene(
	path: String, parent_path: String, node_name: String = ""
) -> Dictionary:
	var checked := resolve(path)
	if not checked.ok:
		return checked
	var NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
	var lookup := NodeEditor.find(parent_path)
	if not lookup.ok:
		return lookup
	var packed: Resource = ResourceLoader.load(checked.path)
	if not packed is PackedScene:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "path is not a PackedScene"}
	if checked.path == current_path():
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "cannot instantiate a scene into itself"
		}
	for dep in ResourceLoader.get_dependencies(checked.path):
		if str(dep).get_slice("::", str(dep).count("::")) == current_path():
			return {
				"ok": false,
				"code": ErrorCodes.CONFLICT,
				"error": "scene depends on the current scene"
			}
	if (
		node_name != ""
		and (node_name.validate_node_name() != node_name or node_name in [".", ".."])
	):
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "invalid node name"}
	var instance: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if instance == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "scene instantiation failed"}
	var parent: Node = lookup.node
	var root := current_root()
	var manager := preload("res://addons/gdapi/runtime/edit_action.gd").undo_redo()
	if manager == null:
		instance.free()
		return {
			"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "UndoRedo manager unavailable"
		}
	instance.name = node_editor._unique_name(
		parent, node_name if node_name != "" else str(instance.name)
	)
	manager.create_action("gdcli: instantiate scene", UndoRedo.MERGE_DISABLE, root)
	manager.add_do_method(parent, "add_child", instance, true)
	# Only the instance root belongs to this scene. Descendants retain the packed-scene owner.
	manager.add_do_method(instance, "set_owner", root)
	manager.add_do_reference(instance)
	manager.add_undo_method(parent, "remove_child", instance)
	manager.commit_action()
	if (
		instance.get_parent() != parent
		or instance.owner != root
		or instance.scene_file_path != checked.path
	):
		manager.get_history_undo_redo(manager.get_object_history_id(root)).undo()
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "instance read-back failed; rolled back"
		}
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"path": checked.path,
		"node_path": node_editor._user_path_for(instance),
		"scene_file_path": instance.scene_file_path
	}


static func delete_scene(path: String, dry_run: bool, close_open: bool) -> Dictionary:
	var checked := PathGuard.validate(path, "delete")
	if not checked.ok:
		return checked
	path = checked.path
	if path.get_extension().to_lower() not in ["tscn", "scn"]:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "scene/delete requires a .tscn or .scn scene"
		}
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "scene does not exist"}
	var references: Array = []
	_scene_references("res://", path, references)
	var main_scene := ResourceUID.ensure_path(
		str(ProjectSettings.get_setting("application/run/main_scene", ""))
	)
	if main_scene == path:
		references.append("project.godot:application/run/main_scene")
	for root in EditorInterface.get_open_scene_roots():
		_live_scene_references(root, path, references)
	var opened := path in EditorInterface.get_open_scenes()
	if dry_run:
		AuditLog.record(
			"scene/delete",
			"dangerous",
			{"path": path, "dry_run": true, "references": references, "open": opened},
			true,
			""
		)
		return {
			"ok": true,
			"changed": false,
			"undoable": false,
			"dry_run": true,
			"path": path,
			"references": references,
			"open": opened,
			"can_delete":
			references.is_empty() and (not opened or (close_open and current_path() == path))
		}
	if not references.is_empty():
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "scene is still referenced: " + str(references)
		}
	if opened and (not close_open or current_path() != path):
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error":
			"open scene must be current and close_open=true; switch/close other tabs explicitly"
		}
	if opened and path in EditorInterface.get_unsaved_scenes():
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "save or discard unsaved scene changes before deletion"
		}
	var original := FileAccess.get_file_as_bytes(path)
	var uid_path := path + ".uid"
	var had_uid := FileAccess.file_exists(uid_path)
	var uid_bytes := FileAccess.get_file_as_bytes(uid_path) if had_uid else PackedByteArray()
	var uid := ResourceLoader.get_resource_uid(path)
	if opened:
		var close_error := EditorInterface.close_scene()
		if close_error != OK:
			return {
				"ok": false,
				"code": ErrorCodes.CONFLICT,
				"error": "editor refused to close scene: " + str(close_error)
			}
	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if error == OK and had_uid:
		error = DirAccess.remove_absolute(ProjectSettings.globalize_path(uid_path))
	if error != OK or FileAccess.file_exists(path) or FileAccess.file_exists(uid_path):
		var restore := FileAccess.open(path, FileAccess.WRITE)
		if restore != null:
			restore.store_buffer(original)
			restore.close()
		if had_uid:
			var restore_uid := FileAccess.open(uid_path, FileAccess.WRITE)
			if restore_uid != null:
				restore_uid.store_buffer(uid_bytes)
				restore_uid.close()
		if opened:
			EditorInterface.open_scene_from_path(path)
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "scene deletion failed; restored original files: " + str(error)
		}
	if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
		ResourceUID.remove_id(uid)
	EditorInterface.get_resource_filesystem().scan()
	AuditLog.record(
		"scene/delete",
		"dangerous",
		{"path": path, "dry_run": false, "closed": opened, "undoable": false},
		true,
		""
	)
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"deleted": true,
		"path": path,
		"closed": opened
	}


static func _scene_references(directory: String, target: String, references: Array) -> void:
	for file in DirAccess.get_files_at(directory):
		var candidate := directory.path_join(file)
		if (
			candidate == target
			or file.get_extension().to_lower() not in ["tscn", "scn", "tres", "res"]
		):
			continue
		for dep in ResourceLoader.get_dependencies(candidate):
			var dependency := str(dep)
			var pieces := dependency.split("::")
			if (
				pieces[pieces.size() - 1] == target
				or (
					pieces[0].begins_with("uid://")
					and ResourceUID.text_to_id(pieces[0]) == ResourceLoader.get_resource_uid(target)
				)
			):
				references.append(candidate)
				break
	for child in DirAccess.get_directories_at(directory):
		if child.begins_with(".") or directory.path_join(child) == "res://addons/gdapi":
			continue
		_scene_references(directory.path_join(child), target, references)


static func _live_scene_references(node: Node, target: String, references: Array) -> void:
	for child in node.get_children():
		if child.scene_file_path == target:
			references.append("open scene instance: " + str(child.get_path()))
		_live_scene_references(child, target, references)
