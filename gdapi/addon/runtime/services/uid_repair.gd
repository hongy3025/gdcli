@tool
class_name GdApiUidRepair
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const EXTENSIONS := ["tscn", "tres", "res", "scn", "material", "mesh", "shader", "gdshader"]


static func repair(body: Dictionary) -> Dictionary:
	var dry_run := bool(body.get("dry_run", true))
	var roots: Array[String] = []
	for root in body.get("roots", ["res://"]):
		var checked := _validate_scan_path(String(root))
		if not checked.ok:
			return checked
		var path := String(checked.path)
		if path not in ["res://", "user://"]:
			path = path.trim_suffix("/")
		if path not in roots:
			roots.append(path)
	roots.sort()
	var scan_roots: Array[String] = []
	for root in roots:
		var covered := false
		for parent in scan_roots:
			var prefix := parent if parent.ends_with("://") else parent + "/"
			if root.begins_with(prefix):
				covered = true
				break
		if not covered:
			scan_roots.append(root)
	var paths: Array = []
	for root in scan_roots:
		_collect(root, paths)
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
		change["new_uid"] = str(ResourceUID.create_id())
		planned.append(change)
	if not dry_run:
		# Snapshot every resource and sidecar before the first write. This also
		# lets a failed set_uid restore its partially modified current target.
		for change in planned:
			var checked := PathGuard.validate(change.path, "write")
			if not checked.ok:
				return checked
			var probe: FileAccess = null
			if not FileAccess.get_read_only_attribute(change.path):
				probe = FileAccess.open(change.path, FileAccess.READ_WRITE)
			if probe == null:
				return {
					"ok": false,
					"code": ErrorCodes.PERMISSION_DENIED,
					"error": "UID target is not writable",
					"details": {"failed_path": change.path, "applied": 0}
				}
			change["original_bytes"] = probe.get_buffer(probe.get_length())
			probe.close()
			change["previous_uid_registered"] = false
			change["previous_uid_path"] = ""
			if change.old_uid.is_valid_int():
				var previous_id := int(change.old_uid)
				if ResourceUID.has_id(previous_id):
					change["previous_uid_registered"] = true
					change["previous_uid_path"] = ResourceUID.get_id_path(previous_id)
			var uid_path: String = String(change.path) + ".uid"
			change["uid_sidecar_existed"] = FileAccess.file_exists(uid_path)
			change["uid_sidecar_bytes"] = (
				FileAccess.get_file_as_bytes(uid_path)
				if change.uid_sidecar_existed
				else PackedByteArray()
			)
		var attempted: Array = []
		for change in planned:
			attempted.append(change)
			var error := ResourceSaver.set_uid(change.path, int(change.new_uid))
			var written_uid := int(ResourceLoader.get_resource_uid(change.path))
			if error != OK or written_uid != int(change.new_uid):
				var rollback_failures := _rollback_targets(attempted)
				AuditLog.record(
					"uid/repair", "dangerous", {"path": change.path}, false, ErrorCodes.GODOT_ERROR
				)
				var message := "failed to set UID"
				if not rollback_failures.is_empty():
					message += (
						"; failed to restore original bytes for: " + ", ".join(rollback_failures)
					)
				var reported_changes: Array = []
				for planned_change in planned:
					reported_changes.append(
						{
							"path": planned_change.path,
							"old_uid": planned_change.old_uid,
							"new_uid": planned_change.new_uid,
							"status": planned_change.status
						}
					)
				return {
					"ok": false,
					"code": ErrorCodes.GODOT_ERROR,
					"error": message,
					"changes": reported_changes,
					"details":
					{
						"failed_path": change.path,
						"expected_uid": int(change.new_uid),
						"written_uid": written_uid,
						"applied": attempted.size() - 1,
						"rollback_failures": rollback_failures
					}
				}
		for change in planned:
			change.erase("original_bytes")
			change.erase("uid_sidecar_existed")
			change.erase("uid_sidecar_bytes")
			change.erase("previous_uid_registered")
			change.erase("previous_uid_path")
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


static func _rollback_targets(attempted: Array) -> Array:
	var failures: Array = []
	for raw_index in range(attempted.size() - 1, -1, -1):
		var change: Dictionary = attempted[raw_index]
		if not _restore_bytes(change.path, change.original_bytes):
			failures.append(change.path)
		var uid_path: String = String(change.path) + ".uid"
		if change.uid_sidecar_existed:
			if not _restore_bytes(uid_path, change.uid_sidecar_bytes):
				failures.append(uid_path)
		elif (
			FileAccess.file_exists(uid_path)
			and DirAccess.remove_absolute(ProjectSettings.globalize_path(uid_path)) != OK
		):
			failures.append(uid_path)
		var new_id := int(change.new_uid)
		if ResourceUID.has_id(new_id) and ResourceUID.get_id_path(new_id) == change.path:
			ResourceUID.remove_id(new_id)
		if change.previous_uid_registered:
			var old_id := int(change.old_uid)
			if ResourceUID.has_id(old_id):
				ResourceUID.set_id(old_id, change.previous_uid_path)
			else:
				ResourceUID.add_id(old_id, change.previous_uid_path)
	return failures


static func _restore_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_file_as_bytes(path) == bytes
	file.store_buffer(bytes)
	file.close()
	return FileAccess.get_file_as_bytes(path) == bytes


## Scan containers may be scheme roots; resource writes still use the strict guard.
## Explicit protected roots and protected descendants must remain excluded.
static func _validate_scan_path(path: String) -> Dictionary:
	var checked := PathGuard.validate(path, "read")
	if not checked.ok or String(checked.path).ends_with("://"):
		return checked
	return PathGuard.validate(checked.path, "write")


static func _collect(path: String, result: Array) -> void:
	# A broad project scan must not enter any directory protected by filesystem/write.
	if not _validate_scan_path(path).ok:
		return
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
