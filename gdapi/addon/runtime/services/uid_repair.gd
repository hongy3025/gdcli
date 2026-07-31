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
		for change in planned:
			var error := ResourceSaver.set_uid(change.path, int(change.new_uid))
			if error != OK:
				AuditLog.record(
					"uid/repair", "dangerous", {"path": change.path}, false, ErrorCodes.GODOT_ERROR
				)
				return {
					"ok": false,
					"code": ErrorCodes.GODOT_ERROR,
					"error": "failed to set UID",
					"changes": planned
				}
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
