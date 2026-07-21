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
		"path": str(node.get_path()),
		"type": node.get_class(),
		"scene_file_path": node.scene_file_path,
		"children": [],
	}
	if depth < max_depth:
		for child in node.get_children():
			item.children.append(describe_tree(child, max_depth, depth + 1))
	return item

## 关闭编辑器中当前打开的场景,如果该场景是当前路径则调用 EditorInterface.
## @param path 可选;非空表示关闭指定路径场景(目前仅支持当前)
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

## 保存当前场景到指定路径或原路径.显式提供 path 且目标文件已存在时需要 force=true.
## 未提供 path 时保存到当前场景路径不需要 force (按习惯保存编辑器中的当前场景)。
static func save_scene(path: String, force: bool) -> Dictionary:
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
	var target_exists := FileAccess.file_exists(ProjectSettings.globalize_path(target))
	if explicit and target_exists and not force:
		AuditLog.record(
			"scene/current/save", "file",
			{"path": target, "force": false}, false,
			ErrorCodes.UNSAFE_OPERATION
		)
		return {
			"ok": false,
			"code": ErrorCodes.UNSAFE_OPERATION,
			"error": "scene/current/save requires force:true to overwrite existing path",
		}
	var save_result: int
	if target == current_path():
		save_result = EditorInterface.save_scene()
	else:
		EditorInterface.save_scene_as(target)
		save_result = OK
	if save_result != OK:
		AuditLog.record("scene/current/save", "file", {"path": target}, false, ErrorCodes.GODOT_ERROR)
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "failed to save scene: " + str(save_result),
		}
	AuditLog.record("scene/current/save", "file", {"path": target, "force": force}, true, "")
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

## 返回当前 editor 已打开场景路径数组(目前仅当前场景)
static func list_open_scenes() -> Array:
	var current := current_path()
	if current == "":
		return []
	return [current]
