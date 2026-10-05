## M2 场景编辑服务
##
## 提供当前场景控制、场景打开/保存/关闭、树序列化等只读/写操作的统一入口。
## 渲染端读取使用 EditorInterface,持久化先检查可写性再验证实际磁盘场景。
## 所有写操作产生 audit 记录,失败时返回标准 error code.

@tool
class_name GdApiSceneEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const AtomicFile := preload("res://addons/gdapi/runtime/atomic_file.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

const SCENE_TABS_CONTAINER_CLASS := "EditorSceneTabs"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ScriptAnalysis := preload(
	"res://addons/gdapi/runtime/services/diagnostics_script_analysis.gd"
)


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


## 当前场景是否有未保存改动。以编辑器自身记录为准。
##
## 逐 tab 的脏标记只在场景 tab 标题里暴露（见 _unsaved_flags）：save-as 后编辑器登记的
## 打开路径仍是旧路径，同一个路径可以同时属于脏的 save-as tab 和干净的重开 tab，因此
## 不能用路径归属判断，必须按 tab 索引用实际 scene root 识别当前场景。
static func is_current_scene_unsaved() -> bool:
	var root := current_root()
	if root == null:
		return false
	return _root_tab_is_unsaved(
		root,
		EditorInterface.get_open_scene_roots(),
		EditorInterface.get_open_scenes(),
		EditorInterface.get_unsaved_scenes()
	)


static func _root_tab_is_unsaved(
	target_root: Node, roots: Array, open_paths: PackedStringArray, unsaved_paths: PackedStringArray
) -> bool:
	var flagged := _unsaved_flags(open_paths, unsaved_paths)
	for root_index in roots.size():
		if roots[root_index] != target_root:
			continue
		var open_index := _open_path_index_for_root(root_index, roots, open_paths)
		return flagged.has(open_index)
	return false


## 编辑器只在场景 tab 标题里暴露“逐 tab 未保存”状态：
## EditorSceneTabs 用 UndoRedoManager::is_history_unsaved 渲染 "(*)" 后缀，而该调用
## 未绑定给脚本；get_unsaved_scenes() 只返回经过过滤的路径，save-as 后同一路径可能同时
## 属于脏的 save-as tab 和干净的重开 tab，按路径归属会误判。这里优先读取真实 tab 控件。
static func _unsaved_flags(
	open_paths: PackedStringArray, unsaved_paths: PackedStringArray
) -> Dictionary:
	var from_tabs := _tab_unsaved_flags()
	if from_tabs is Dictionary:
		return from_tabs
	return _unsaved_indexes(open_paths, unsaved_paths)


## 按场景 tab 索引读取未保存标记；控件不可用时返回 null，由调用方回退。
static func _tab_unsaved_flags() -> Variant:
	var bar := _scene_tabs_bar()
	if bar == null:
		return null
	var flagged := {}
	for index in bar.get_tab_count():
		if bar.get_tab_title(index).ends_with("(*)"):
			flagged[index] = true
	return flagged


## 定位编辑器场景 tab 控件；tab 数量必须与编辑器登记的打开场景数一致。
static func _scene_tabs_bar() -> TabBar:
	if not Engine.is_editor_hint():
		return null
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var expected := EditorInterface.get_open_scenes().size()
	for container in base.find_children("*", SCENE_TABS_CONTAINER_CLASS, true, false):
		for candidate in container.find_children("*", "TabBar", true, false):
			var bar: TabBar = candidate
			if bar.get_tab_count() == expected:
				return bar
	return null


## 把"未保存场景路径"解码成 tab 索引。get_unsaved_scenes() 是按 tab 顺序过滤出的
## 有序子序列，因此重复路径必须逐个匹配，不能用路径归属判断。
static func _unsaved_indexes(
	open_paths: PackedStringArray, unsaved_paths: PackedStringArray
) -> Dictionary:
	var flagged := {}
	var next := 0
	for index in open_paths.size():
		if next >= unsaved_paths.size():
			break
		if open_paths[index] == unsaved_paths[next]:
			flagged[index] = true
			next += 1
	return flagged


## get_open_scene_roots() omits null roots, while get_open_scenes() preserves their empty paths.
## Skip only unmatched empty tabs so subsequent root indexes retain their editor-tab mapping.
static func _open_path_index_for_root(
	root_index: int, roots: Array, open_paths: PackedStringArray
) -> int:
	if roots.size() == open_paths.size():
		return root_index
	var matched_roots := 0
	for open_index in open_paths.size():
		if (
			open_paths[open_index].is_empty()
			and matched_roots < roots.size()
			and roots[matched_roots].scene_file_path != ""
		):
			continue
		if matched_roots == root_index:
			return open_index
		matched_roots += 1
	return -1


static func _scene_tab_status(path: String) -> Dictionary:
	return _scene_tab_status_for(
		path,
		EditorInterface.get_open_scene_roots(),
		EditorInterface.get_open_scenes(),
		EditorInterface.get_unsaved_scenes()
	)


static func _scene_tab_status_for(
	path: String, roots: Array, open_paths: PackedStringArray, unsaved_paths: PackedStringArray
) -> Dictionary:
	var opened := false
	var unsaved := false
	var flagged := _unsaved_flags(open_paths, unsaved_paths)
	for root_index in roots.size():
		var root: Node = roots[root_index]
		if root == null or root.scene_file_path != path:
			continue
		var open_index := _open_path_index_for_root(root_index, roots, open_paths)
		if open_index < 0:
			continue
		opened = true
		unsaved = flagged.has(open_index)
	return {"open": opened, "unsaved": unsaved}


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
	var root := current_root()
	if root == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	var original_path := root.scene_file_path
	var target := path if path != "" else original_path
	var editor_plugin: Object = EditAction.plugin()
	if editor_plugin == null:
		return _save_failure(target, "editor plugin unavailable")
	var prepared := _prepare_scene_save(target)
	if not prepared.ok:
		return prepared
	target = prepared.path
	var expected := PackedScene.new()
	var pack_error := expected.pack(root)
	if pack_error != OK:
		ResourceEditor._restore_file(target, prepared.existed, prepared.before)
		return _save_failure(target, "scene packing failed: " + str(pack_error))
	var was_unsaved := is_current_scene_unsaved()
	# scene_saved is not proof of success (Godot emits it on failed writes too).
	# It is the point after editor changes/pre-save notifications and animation RESET,
	# but before animation restoration, where the packed state matches the intended file.
	var verification := {"pack_error": ERR_UNAVAILABLE}
	var capture := func(saved_path: String) -> void:
		if saved_path == target:
			verification.pack_error = expected.pack(root)
	editor_plugin.connect("scene_saved", capture)
	# Avoid preview generation, which can yield into unrelated editor work.
	EditorInterface.save_scene_as(target, false)
	editor_plugin.disconnect("scene_saved", capture)
	var persisted := ResourceLoader.load(
		target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP
	)
	var contents_match: bool = (
		verification.pack_error == OK
		and persisted is PackedScene
		and ResourceEditor._equivalent(_scene_contents(expected), _scene_contents(persisted))
	)
	var still_unsaved := is_current_scene_unsaved()
	if not contents_match or root.scene_file_path != target or still_unsaved:
		# Capture the real failed boundary before rollback changes path/dirty state.
		var details := {
			"pack_error": verification.pack_error,
			"read_back_packed_scene": persisted is PackedScene,
			"contents_match": contents_match,
			"current_path": root.scene_file_path,
			"target": target,
			"unsaved": still_unsaved,
			"open_paths": EditorInterface.get_open_scenes(),
			"unsaved_paths": EditorInterface.get_unsaved_scenes(),
		}
		var restored := ResourceEditor._restore_file(target, prepared.existed, prepared.before)
		restored = (
			ResourceEditor._restore_file(target + ".uid", prepared.uid_existed, prepared.uid_before)
			and restored
		)
		root.scene_file_path = original_path
		if was_unsaved:
			EditorInterface.mark_scene_as_unsaved()
		var message := "scene save/read-back failed: " + JSON.stringify(details)
		if not restored:
			message += "; disk rollback failed"
		return _save_failure(target, message)
	AuditLog.record("scene/current/save", "file", {"path": target}, true, "")
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": target}


## PackedScene 的名字/路径表索引在文本落盘后会变化，比较解码后的语义而非 _bundled。
static func _scene_contents(scene: PackedScene) -> Dictionary:
	var state := scene.get_state()
	var nodes: Array = []
	for index in state.get_node_count():
		var properties := {}
		for property_index in state.get_node_property_count(index):
			properties[state.get_node_property_name(index, property_index)] = (
				state.get_node_property_value(index, property_index)
			)
		var groups := state.get_node_groups(index)
		groups.sort()
		(
			nodes
			. append(
				{
					"path": String(state.get_node_path(index)).simplify_path(),
					"parent": String(state.get_node_path(index, true)).simplify_path(),
					"owner": String(state.get_node_owner_path(index)).simplify_path(),
					"name": state.get_node_name(index),
					"type": state.get_node_type(index),
					"index": state.get_node_index(index),
					"instance": state.get_node_instance(index),
					"placeholder": state.get_node_instance_placeholder(index),
					"groups": groups,
					"properties": properties,
				}
			)
		)
	var connections: Array = []
	for index in state.get_connection_count():
		(
			connections
			. append(
				{
					"source": String(state.get_connection_source(index)).simplify_path(),
					"target": String(state.get_connection_target(index)).simplify_path(),
					"signal": state.get_connection_signal(index),
					"method": state.get_connection_method(index),
					"flags": state.get_connection_flags(index),
					"binds": state.get_connection_binds(index),
					"unbinds": state.get_connection_unbinds(index),
				}
			)
		)
	var base := state.get_base_scene_state()
	return {
		"nodes": nodes,
		"connections": connections,
		"base": base.get_path() if base != null else "",
		"editable_instances": scene.get("_bundled").get("editable_instances", []),
	}


static func _prepare_scene_save(target: String) -> Dictionary:
	var checked := PathGuard.validate(target, "write")
	if not checked.ok:
		return _save_failure(target, checked.error, checked.code)
	target = checked.path
	if target.get_extension().to_lower() not in ["tscn", "scn"]:
		return _save_failure(
			target, "scene save requires a .tscn or .scn path", ErrorCodes.INVALID_PARAM
		)
	var probe_file := AtomicFile.create_temp_file(target, "")
	if not probe_file.ok:
		return _save_failure(
			target, "scene file is not writable: " + probe_file.error, ErrorCodes.PERMISSION_DENIED
		)
	var abs_target: String = probe_file.target_path
	var existed := FileAccess.file_exists(abs_target)
	var before := PackedByteArray()
	if existed:
		var target_file := FileAccess.open(abs_target, FileAccess.READ_WRITE)
		if target_file == null:
			AtomicFile.remove(probe_file)
			return _save_failure(target, "scene file is not writable", ErrorCodes.PERMISSION_DENIED)
		before = target_file.get_buffer(target_file.get_length())
		target_file.close()
	var remove_error := AtomicFile.remove(probe_file)
	if remove_error != OK:
		return _save_failure(target, "could not remove scene writability probe")
	var uid_path := abs_target + ".uid"
	var uid_existed := FileAccess.file_exists(uid_path)
	return {
		"ok": true,
		"path": target,
		"existed": existed,
		"before": before,
		"uid_existed": uid_existed,
		"uid_before": FileAccess.get_file_as_bytes(uid_path) if uid_existed else PackedByteArray()
	}


static func _save_failure(
	path: String, message: String, code: String = ErrorCodes.GODOT_ERROR
) -> Dictionary:
	AuditLog.record("scene/current/save", "file", {"path": path}, false, code)
	return {"ok": false, "code": code, "error": message, "changed": false, "saved": false}


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
	var manager := EditAction.undo_redo()
	if manager == null:
		instance.free()
		return {
			"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "UndoRedo manager unavailable"
		}
	instance.name = NodeEditor._unique_name(
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
		"node_path": NodeEditor._user_path_for(instance),
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
	var uid := ResourceLoader.get_resource_uid(path)
	var references: Array = []
	_scene_references("res://", path, uid, references)
	var main_scene := ResourceUID.ensure_path(
		str(ProjectSettings.get_setting("application/run/main_scene", ""))
	)
	if main_scene == path:
		references.append("project.godot:application/run/main_scene")
	for root in EditorInterface.get_open_scene_roots():
		_live_scene_references(root, path, references)
	var tab_status := _scene_tab_status(path)
	var opened: bool = tab_status.open
	var unsaved: bool = tab_status.unsaved
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
			(
				references.is_empty()
				and not unsaved
				and (not opened or (close_open and current_path() == path))
			)
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
	if unsaved:
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "save or discard unsaved scene changes before deletion"
		}
	var original := FileAccess.get_file_as_bytes(path)
	var uid_path := path + ".uid"
	var had_uid := FileAccess.file_exists(uid_path)
	var uid_bytes := FileAccess.get_file_as_bytes(uid_path) if had_uid else PackedByteArray()
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


static func _scene_references(
	directory: String, target: String, target_uid: int, references: Array
) -> void:
	for file in DirAccess.get_files_at(directory):
		var candidate := directory.path_join(file)
		var extension := file.get_extension().to_lower()
		if candidate == target or extension not in ["gd", "tscn", "scn", "tres", "res"]:
			continue
		if extension == "gd":
			# The lexical analyzer reads source only; loading a GDScript would run
			# _static_init(), and merely parsing preload may load its dependencies.
			for reference in ScriptAnalysis.scan(candidate).references:
				if (
					reference.kind in ["load", "preload"]
					and reference.status == "resolved"
					and _dependency_matches(str(reference.target), target, target_uid)
				):
					references.append(candidate)
					break
		else:
			for dependency in ResourceLoader.get_dependencies(candidate):
				if _dependency_matches(str(dependency), target, target_uid):
					references.append(candidate)
					break
	for child in DirAccess.get_directories_at(directory):
		if child.begins_with(".") or directory.path_join(child) == "res://addons/gdapi":
			continue
		_scene_references(directory.path_join(child), target, target_uid, references)


static func _dependency_matches(dependency: String, target: String, target_uid: int) -> bool:
	var pieces := dependency.split("::")
	return (
		pieces[pieces.size() - 1].simplify_path() == target
		or (
			target_uid != ResourceUID.INVALID_ID
			and pieces[0].begins_with("uid://")
			and ResourceUID.text_to_id(pieces[0]) == target_uid
		)
	)


static func _live_scene_references(node: Node, target: String, references: Array) -> void:
	for child in node.get_children():
		if child.scene_file_path == target:
			references.append("open scene instance: " + str(child.get_path()))
		_live_scene_references(child, target, references)
