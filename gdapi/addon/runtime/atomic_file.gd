@tool
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")


static func create_temp_file(path: String, content: String) -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "error": checked.error}
	var root_path := "user://" if checked.path.begins_with("user://") else "res://"
	var protected_roots := PackedStringArray()
	for protected_path in PathGuard.BLOCKED_WRITE_PREFIXES:
		protected_roots.append(ProjectSettings.globalize_path(protected_path.trim_suffix("/")))
	return GdApiServer.create_temp_file_for_path(
		ProjectSettings.globalize_path(checked.path),
		ProjectSettings.globalize_path(root_path),
		protected_roots,
		content.to_utf8_buffer()
	)


static func commit(temp_file: Dictionary) -> int:
	var rename_error: int = DirAccess.rename_absolute(temp_file.path, temp_file.target_path)
	if rename_error == OK:
		return OK
	remove(temp_file)
	return rename_error


static func remove(temp_file: Dictionary) -> int:
	return DirAccess.remove_absolute(temp_file.path)
