@tool
class_name GdApiPathGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const BLOCKED_WRITE_PREFIXES := [
	"res://addons/gdapi/",
	"res://.godot/",
]

static func validate(path: String, mode: String = "read") -> Dictionary:
	if path.strip_edges().is_empty():
		return _err("path is required", ErrorCodes.INVALID_PATH)
	if path.is_absolute_path():
		return _err("absolute system paths are not allowed", ErrorCodes.INVALID_PATH)
	var normalized := normalize(path)
	if normalized.contains(".."):
		return _err("path traversal is not allowed", ErrorCodes.INVALID_PATH)
	if not normalized.begins_with("res://") and not normalized.begins_with("user://"):
		return _err("only res:// and user:// paths are allowed", ErrorCodes.INVALID_PATH)
	if mode == "write" or mode == "delete":
		for prefix in BLOCKED_WRITE_PREFIXES:
			if normalized.begins_with(prefix):
				return _err("path is protected: " + normalized, ErrorCodes.PERMISSION_DENIED, 403)
	return {"ok": true, "path": normalized}

static func normalize(path: String) -> String:
	var p := path.strip_edges().replace("\\", "/")
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	return "res://" + p.trim_prefix("/")

static func _err(message: String, code: String, status: int = 400) -> Dictionary:
	return {"ok": false, "error": message, "code": code, "status": status}
