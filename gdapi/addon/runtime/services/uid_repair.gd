@tool
class_name GdApiUidRepair
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const EXTENSIONS := ["tscn", "tres", "res", "scn", "material", "mesh", "shader", "gdshader"]


static func repair(body: Dictionary) -> Dictionary:
	var dry_run := bool(body.get("dry_run", true))
	var paths: Array = []
	for root in body.get("roots", ["res://"]):
		var checked := PathGuard.validate(String(root), "read")
		if not checked.ok:
			return checked
		if checked.path.begins_with("res://addons/gdapi/"):
			return {"ok": false, "code": ErrorCodes.PERMISSION_DENIED, "error": "protected root"}
		_collect(checked.path, paths)
	paths.sort()
	var changes: Array = []
	var seen: Dictionary = {}
	for path in paths:
		var uid := ResourceLoader.get_resource_uid(path)
		var old := "" if uid < 0 else str(uid)
		var status := "ok"
		if uid < 0:
			status = "missing"
		elif seen.has(uid):
			status = "collision"
		if uid >= 0:
			seen[uid] = path
		if status != "ok":
			changes.append({"path": path, "old_uid": old, "new_uid": "", "status": status})
	var planned: Array = []
	for change in changes:
		var new_uid := str(ResourceUID.create_id())
		change["new_uid"] = new_uid
		planned.append(change)
	if not dry_run:
		var applied: Array = []
		for change in planned:
			var error := ResourceSaver.set_uid(change.path, int(change.new_uid))
			var written_uid := int(ResourceLoader.get_resource_uid(change.path))
			if error != OK or written_uid != int(change.new_uid):
				# 回读校验：Godot 在目标不可写时可能返回 OK 却什么都没写，
				# 必须当成失败，否则会留下「改了一半」的 UID。
				var rollback_failures := _rollback_applied(applied)
				AuditLog.record(
					"uid/repair", "dangerous", {"path": change.path}, false, ErrorCodes.GODOT_ERROR
				)
				return {
					"ok": false,
					"code": ErrorCodes.GODOT_ERROR,
					"error": "failed to set UID",
					"changes": planned,
					"details":
					{
						"failed_path": change.path,
						"expected_uid": int(change.new_uid),
						"written_uid": written_uid,
						"applied": applied.size(),
						"rollback_failures": rollback_failures
					}
				}
			applied.append(change)
	AuditLog.record(
		"uid/repair",
		"dangerous",
		{"roots": body.get("roots", ["res://"]), "changed": not dry_run and not planned.is_empty()},
		true
	)
	return {
		"ok": true,
		"scanned": paths.size(),
		"missing": changes.filter(func(x): return x.status == "missing").size(),
		"collisions": changes.filter(func(x): return x.status == "collision").size(),
		"changes": changes,
		"changed": not dry_run and not changes.is_empty(),
		"undoable": false
	}


## 回滚已写入的 UID。原值为空的条目（此前缺失 UID）无法还原，计入失败列表。
static func _rollback_applied(applied: Array) -> Array:
	var failures: Array = []
	for raw_index in range(applied.size() - 1, -1, -1):
		var change: Dictionary = applied[raw_index]
		var previous := String(change.old_uid)
		if previous.is_empty() or not previous.is_valid_int():
			failures.append(change.path)
			continue
		if ResourceSaver.set_uid(change.path, int(previous)) != OK:
			failures.append(change.path)
	return failures


static func _collect(path: String, result: Array) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(absolute):
		if path.get_extension().to_lower() in EXTENSIONS:
			result.append(path)
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not name.begins_with("."):
			_collect(path.trim_suffix("/") + "/" + name, result)
		name = dir.get_next()
	dir.list_dir_end()
