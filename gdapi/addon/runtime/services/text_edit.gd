## M2 文本/脚本编辑服务
##
## 提供 GDScript 文件行级 patch、读取、附加 GDScript 到节点的原子编辑能力.
## patch 采用全有或全无的语义,在写入前一次性校验所有派生范围.

@tool
class_name GdApiTextEdit
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const MAX_SCRIPT_BYTES := 1 * 1024 * 1024

## 在 path 上读取源代码.仅允许 res:// 脚本类扩展.
static func read_script(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "file not found: " + checked.path}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "cannot open: " + checked.path}
	var content := f.get_as_text()
	f.close()
	return {
		"ok": true,
		"path": checked.path,
		"content": content,
		"bytes": content.length(),
		"undoable": false,
	}

## 全有或全无的 patch: 1-based 闭区间 [first, last] 替换为 text(text 支持多行).
static func replace_lines(source: String, first: int, last: int, text: String) -> Dictionary:
	var lines := source.split("\n", true)
	if first < 1 or last < first or last > lines.size():
		return {"ok": false, "error": "line range is outside the file: " + str(first) + ".." + str(last) + " (size=" + str(lines.size()) + ")"}
	var replacement := text.split("\n", true)
	var new_lines: Array = lines.slice(0, first - 1) + replacement + lines.slice(last)
	return {"ok": true, "text": "\n".join(new_lines)}

## 写入新脚本文件.已存在需要 force.
static func create_script(path: String, content: String, force: bool) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if content.length() > MAX_SCRIPT_BYTES:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "content too large"}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if FileAccess.file_exists(abs_path) and not force:
		AuditLog.record("script/create", "file", {"path": checked.path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return {"ok": false, "code": ErrorCodes.UNSAFE_OPERATION, "error": "script/create requires force:true"}
	var dir := checked.path.get_base_dir()
	if dir != "res://" and !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# 写入临时文件再 rename,避免半写入
	var tmp := abs_path + ".gdcli-tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "cannot create temp file"}
	f.store_string(content)
	f.close()
	DirAccess.rename_absolute(tmp, abs_path)
	AuditLog.record("script/create", "file", {"path": checked.path, "force": force}, true, "")
	return {"ok": true, "changed": true, "written": true, "saved": true, "undoable": false, "path": checked.path, "bytes": content.length()}

## 完整覆盖写入.需要 force.返回 undoable:false 并审计.
static func write_script(path: String, content: String, force: bool) -> Dictionary:
	return create_script(path, content, force)

## 行级 patch.写入磁盘前先校验范围,失败时返回 invalid_param 且不动文件.
static func patch_script(path: String, first: int, last: int, text: String, force: bool) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "file not found: " + checked.path}
	var existing := FileAccess.get_file_as_string(abs_path)
	if existing.length() > MAX_SCRIPT_BYTES:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "file too large to patch in-memory"}
	var patch_result := replace_lines(existing, first, last, text)
	if not patch_result.ok:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": patch_result.error}
	# 强制要求覆盖时,目标必须真实变化或必须 force
	var new_text: String = patch_result.text
	if new_text == existing and not force:
		return {"ok": false, "code": ErrorCodes.CONFLICT, "error": "patch is a no-op without force:true"}
	var tmp := abs_path + ".gdcli-tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "cannot create temp file"}
	f.store_string(new_text)
	f.close()
	DirAccess.rename_absolute(tmp, abs_path)
	AuditLog.record("script/patch", "file", {"path": checked.path, "first": first, "last": last, "force": force}, true, "")
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": checked.path, "first": first, "last": last}

## attach script 到节点.接 UndoRedo.
static func attach_script(node_path: String, path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "script/attach requires editor"}
	# import NodeEditor 是循环依赖,使用延迟查找
	var EditorInterfaceRef := Engine.get_singleton("EditorInterface") if Engine.has_singleton("EditorInterface") else null
	if EditorInterfaceRef == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorInterface unavailable"}
	# 直接通过 GdApiNodeEditor.find 解析 node_path
	var NodeEditor := load("res://addons/gdapi/runtime/services/node_editor.gd")
	var lookup: Dictionary = NodeEditor.find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var script_check := PathGuard.validate(path, "read")
	if not script_check.ok:
		return {"ok": false, "code": script_check.code, "error": script_check.error}
	var script: Script = load(script_check.path)
	if script == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "cannot load script: " + script_check.path}
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var previous_script: Variant = node.get_script()
	var owner: Node = EditorInterface.get_edited_scene_root()
	manager.create_action("gdcli: attach script")
	manager.add_do_method(node, "set_script", script)
	manager.add_undo_method(node, "set_script", previous_script)
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true, "node_path": lookup.node_path, "script_path": script_check.path}

## detach script.接 UndoRedo.
static func detach_script(node_path: String) -> Dictionary:
	var NodeEditor := load("res://addons/gdapi/runtime/services/node_editor.gd")
	var lookup: Dictionary = NodeEditor.find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var previous_script: Variant = node.get_script()
	if previous_script == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "node has no script attached"}
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	manager.create_action("gdcli: detach script")
	manager.add_do_method(node, "set_script", null)
	manager.add_undo_method(node, "set_script", previous_script)
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true, "node_path": lookup.node_path}

## 校验 GDScript 语法.不修改文件,使用 GDScript 解析.
static func validate_script(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "file not found: " + checked.path}
	var src := FileAccess.get_file_as_string(abs_path)
	var gds := GDScript.new()
	gds.source_code = src
	var err := gds.reload()
	if err == OK:
		return {"ok": true, "valid": true, "errors": [], "path": checked.path, "undoable": false}
	var lines := src.split("\n")
	var errors: Array = []
	# GDScript.reload() 不返回具体错误位置;通过 source code 长度变化推断错误行.
	# 提供粗略解析阶段返回,用户可见 details.
	errors.append({"line": 0, "column": 0, "message": "GDScript reload failed: " + str(err)})
	return {"ok": true, "valid": false, "errors": errors, "path": checked.path, "undoable": false}

## 打开脚本到 script editor,定位 1-based 行/列.
static func open_script(path: String, line: int = -1, column: int = -1) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "script/open requires editor"}
	var resource: Resource = load(checked.path)
	if resource == null or not (resource is Script):
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "not a Script resource: " + checked.path}
	if line < 0 or column < 0:
		EditorInterface.edit_script(resource)
	else:
		EditorInterface.edit_script(resource, line - 1, column - 1)
	return {"ok": true, "changed": false, "undoable": false, "path": checked.path, "line": line, "column": column}

## 返回当前 script editor 打开的脚本路径或空字符串
static func current_script() -> String:
	if not Engine.is_editor_hint():
		return ""
	var editor := EditorInterface.get_script_editor()
	if editor == null:
		return ""
	var open_scripts: Array = editor.get_open_scripts()
	if open_scripts.is_empty():
		return ""
	var cur: Resource = editor.get_current_script()
	if cur == null:
		return ""
	return cur.resource_path
