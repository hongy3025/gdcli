@tool
class_name GdApiBulkFileService
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const MAX_FILES := 1000
const MAX_REPLACEMENTS := 10000
const TRASH_ROOT := "res://.godot/gdapi-trash"
const REPLACE_STAGE_ROOT := "res://.godot/gdapi-replace"


static func delete(body: Dictionary) -> Dictionary:
	var paths: Array = body.get("paths", [])
	if typeof(paths) != TYPE_ARRAY or paths.is_empty() or paths.size() > MAX_FILES:
		return _error(ErrorCodes.INVALID_PARAM, "paths must contain 1..1000 files")
	var plan := _delete_plan(paths)
	if not plan.ok:
		return plan
	if bool(body.get("dry_run", false)):
		return plan
	if not bool(body.get("force", false)):
		return _error(ErrorCodes.UNSAFE_OPERATION, "batch delete requires force:true")
	if String(body.get("plan_hash", "")) != plan.plan_hash:
		return _error(ErrorCodes.CONFLICT, "plan_hash does not match current files")
	var operation_id := "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	var trash := "%s/%s" % [TRASH_ROOT, operation_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(trash))
	var manifest: Array = []
	for entry in plan.operations:
		var source: String = entry.path
		var destination := "%s/%s" % [trash, source.trim_prefix("res://")]
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(destination.get_base_dir())
		)
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(destination)
			)
			!= OK
		):
			_rollback_manifest(manifest)
			return _error(ErrorCodes.GODOT_ERROR, "batch delete rolled back")
		var uid := source + ".uid"
		var manifest_entry := {
			"source": source,
			"trash": destination,
			"uid_source": uid,
			"uid_trash": destination + ".uid"
		}
		if FileAccess.file_exists(ProjectSettings.globalize_path(uid)):
			var uid_destination := destination + ".uid"
			if (
				DirAccess.rename_absolute(
					ProjectSettings.globalize_path(uid),
					ProjectSettings.globalize_path(uid_destination)
				)
				!= OK
			):
				_rollback_manifest(manifest)
				DirAccess.rename_absolute(
					ProjectSettings.globalize_path(destination),
					ProjectSettings.globalize_path(source)
				)
				return _error(ErrorCodes.GODOT_ERROR, "batch delete rolled back")
		manifest.append(manifest_entry)
	var mf := FileAccess.open(
		ProjectSettings.globalize_path(trash + "/manifest.json"), FileAccess.WRITE
	)
	if mf == null:
		_rollback_manifest(manifest)
		return _error(ErrorCodes.GODOT_ERROR, "cannot write recovery manifest")
	mf.store_string(JSON.stringify({"operation_id": operation_id, "entries": manifest}))
	mf.close()
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"deleted": manifest.size(),
		"operation_id": operation_id,
		"manifest": manifest,
		"plan_hash": plan.plan_hash
	}


static func replace(body: Dictionary) -> Dictionary:
	var root := String(body.get("root", "res://"))
	var checked := PathGuard.validate(root, "read")
	if not checked.ok:
		return checked
	var find_text := String(body.get("find", ""))
	var replacement := String(body.get("replace", ""))
	if find_text.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "find is required")
	var matches: Array = []
	var scan := _scan_files(checked.path, find_text, replacement, matches)
	if not scan.ok:
		return scan
	var plan := {"ok": true, "operations": matches, "plan_hash": _hash_plan(matches)}
	if bool(body.get("dry_run", false)):
		return plan
	if not bool(body.get("force", false)):
		return _error(ErrorCodes.UNSAFE_OPERATION, "batch replace requires force:true")
	if String(body.get("plan_hash", "")) != plan.plan_hash:
		return _error(ErrorCodes.CONFLICT, "plan_hash does not match current files")
	var operation_id := "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	var stage_root := "%s/%s" % [REPLACE_STAGE_ROOT, operation_id]
	var stage_dir := ProjectSettings.globalize_path(stage_root)
	DirAccess.make_dir_recursive_absolute(stage_dir.path_join("staged"))
	DirAccess.make_dir_recursive_absolute(stage_dir.path_join("backups"))
	var changed := 0
	for index in range(matches.size()):
		var operation: Dictionary = matches[index]
		var file := FileAccess.open(ProjectSettings.globalize_path(operation.path), FileAccess.READ)
		if file == null:
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.CONFLICT, "source changed during apply")
		var text := file.get_as_text()
		file.close()
		if (
			FileAccess.get_sha256(ProjectSettings.globalize_path(operation.path))
			!= operation.sha256
		):
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.CONFLICT, "source changed during apply")
		var output := text.replace(find_text, replacement)
		var staged := stage_root.path_join("staged").path_join("%d" % index)
		var out := FileAccess.open(ProjectSettings.globalize_path(staged), FileAccess.WRITE)
		if out == null:
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.GODOT_ERROR, "cannot stage replacement")
		out.store_string(output)
		out.close()
		operation["staged"] = staged
		operation["backup"] = stage_root.path_join("backups").path_join("%d" % index)
		matches[index] = operation
		changed += int(operation.replacements)
	var debug_fail_after := _debug_fail_after()
	var applied: Array = []
	for index in range(matches.size()):
		if debug_fail_after >= 0 and index >= debug_fail_after:
			_rollback_replace(matches, applied)
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.GODOT_ERROR, "injected failure for testing")
		var operation: Dictionary = matches[index]
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(operation.path),
				ProjectSettings.globalize_path(operation.backup)
			)
			!= OK
		):
			_rollback_replace(matches, applied)
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.GODOT_ERROR, "batch replace rolled back")
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(operation.staged),
				ProjectSettings.globalize_path(operation.path)
			)
			!= OK
		):
			_rollback_replace(matches, applied + [index])
			_cleanup_replace_stage(stage_root)
			return _error(ErrorCodes.GODOT_ERROR, "batch replace rolled back")
		applied.append(index)
	_cleanup_replace_stage(stage_root)
	return {
		"ok": true,
		"changed": changed > 0,
		"undoable": false,
		"files": matches.size(),
		"replacements": changed,
		"plan_hash": plan.plan_hash
	}


static func _rollback_replace(matches: Array, applied: Array) -> void:
	for raw_index in range(applied.size() - 1, -1, -1):
		var index := int(applied[raw_index])
		var operation: Dictionary = matches[index]
		var target := ProjectSettings.globalize_path(operation.path)
		var backup := ProjectSettings.globalize_path(operation.backup)
		if FileAccess.file_exists(target):
			DirAccess.remove_absolute(target)
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, target)


static func _cleanup_replace_stage(stage_root: String) -> void:
	_remove_tree(
		ProjectSettings.globalize_path(stage_root),
		ProjectSettings.globalize_path(REPLACE_STAGE_ROOT)
	)


static func _remove_tree(path: String, root: String) -> void:
	if path != root and not path.begins_with(root + "/"):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		for file_name in dir.get_files():
			DirAccess.remove_absolute(path.path_join(file_name))
		for dir_name in dir.get_directories():
			_remove_tree(path.path_join(dir_name), root)
	DirAccess.remove_absolute(path)


static func recover(operation_id: String) -> Dictionary:
	if operation_id.is_empty() or operation_id.contains("/") or operation_id.contains("\\"):
		return _error(ErrorCodes.INVALID_PARAM, "invalid operation_id")
	var trash := "%s/%s/manifest.json" % [TRASH_ROOT, operation_id]
	var file := FileAccess.open(ProjectSettings.globalize_path(trash), FileAccess.READ)
	if file == null:
		return _error(ErrorCodes.NOT_FOUND, "recovery manifest not found")
	var parsed := JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return _error(ErrorCodes.GODOT_ERROR, "invalid recovery manifest")
	if bool(parsed.get("recovered", false)):
		return _error(ErrorCodes.CONFLICT, "recovery has already completed")
	var entries: Array = parsed.get("entries", [])
	var restored := 0
	for entry in entries:
		if FileAccess.file_exists(ProjectSettings.globalize_path(entry.source)):
			return _error(ErrorCodes.CONFLICT, "recovery destination already exists")
		if (
			entry.has("uid_source")
			and FileAccess.file_exists(ProjectSettings.globalize_path(entry.uid_source))
		):
			return _error(ErrorCodes.CONFLICT, "recovery destination already exists")
	for entry in entries:
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(entry.source.get_base_dir())
		)
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(entry.trash),
				ProjectSettings.globalize_path(entry.source)
			)
			!= OK
		):
			return _error(ErrorCodes.GODOT_ERROR, "recovery failed")
		if (
			entry.has("uid_trash")
			and FileAccess.file_exists(ProjectSettings.globalize_path(entry.uid_trash))
		):
			if (
				DirAccess.rename_absolute(
					ProjectSettings.globalize_path(entry.uid_trash),
					ProjectSettings.globalize_path(entry.uid_source)
				)
				!= OK
			):
				return _error(ErrorCodes.GODOT_ERROR, "UID recovery failed")
		restored += 1
	parsed["recovered"] = true
	parsed["recovered_at"] = Time.get_unix_time_from_system()
	var updated := FileAccess.open(ProjectSettings.globalize_path(trash), FileAccess.WRITE)
	if updated != null:
		updated.store_string(JSON.stringify(parsed))
		updated.close()
	return {"ok": true, "changed": restored > 0, "undoable": false, "restored": restored}


static func _delete_plan(paths: Array) -> Dictionary:
	var operations: Array = []
	for raw in paths:
		var checked := PathGuard.validate(String(raw), "delete")
		if not checked.ok:
			return checked
		if not FileAccess.file_exists(ProjectSettings.globalize_path(checked.path)):
			return _error(ErrorCodes.NOT_FOUND, "file not found: %s" % checked.path)
		operations.append(
			{
				"path": checked.path,
				"sha256": FileAccess.get_sha256(ProjectSettings.globalize_path(checked.path))
			}
		)
	operations.sort_custom(func(a, b): return a.path < b.path)
	return {"ok": true, "operations": operations, "plan_hash": _hash_plan(operations)}


static func _scan_files(
	root: String, find_text: String, replacement: String, matches: Array
) -> Dictionary:
	var dir := DirAccess.open(root)
	if dir == null:
		return _error(ErrorCodes.NOT_FOUND, "root not found")
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name != ".godot" and not name.begins_with("."):
			var path := root.path_join(name)
			if dir.current_is_dir():
				var nested := _scan_files(path, find_text, replacement, matches)
				if not nested.ok:
					return nested
			else:
				var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.READ)
				if file != null:
					var text := file.get_as_text()
					file.close()
					var count := text.count(find_text)
					if count > 0:
						matches.append(
							{
								"path": path,
								"sha256":
								FileAccess.get_sha256(ProjectSettings.globalize_path(path)),
								"replacements": count
							}
						)
						if (
							matches.size() > MAX_FILES
							or _replacement_count(matches) > MAX_REPLACEMENTS
						):
							return _error(ErrorCodes.INVALID_PARAM, "bulk replace exceeds limits")
		name = dir.get_next()
	dir.list_dir_end()
	return {"ok": true}


static func _replacement_count(items: Array) -> int:
	var total := 0
	for item in items:
		total += int(item.replacements)
	return total


static func _hash_plan(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(value).to_utf8_buffer())
	return context.finish().hex_encode()


static func _rollback_manifest(manifest: Array) -> void:
	for index in range(manifest.size() - 1, -1, -1):
		var entry: Dictionary = manifest[index]
		if FileAccess.file_exists(ProjectSettings.globalize_path(entry.trash)):
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(entry.trash),
				ProjectSettings.globalize_path(entry.source)
			)
		if (
			entry.has("uid_trash")
			and FileAccess.file_exists(ProjectSettings.globalize_path(entry.uid_trash))
		):
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(entry.uid_trash),
				ProjectSettings.globalize_path(entry.uid_source)
			)


static func _debug_fail_after() -> int:
	var path := ProjectSettings.globalize_path("res://.gdapi-debug-apply-fail")
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var text := f.get_as_text().strip_edges()
	f.close()
	if text.is_empty() or not text.is_valid_int():
		return -1
	return int(text)


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
