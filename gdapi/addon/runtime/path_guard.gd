@tool
class_name GdApiPathGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const BLOCKED_WRITE_PREFIXES := [
	"res://addons/gdapi/",
	"res://.godot/",
]


static func validate(path: String, mode: String = "read") -> Dictionary:
	if mode not in ["read", "write", "delete"]:
		return _err("invalid path mode: " + mode, ErrorCodes.INVALID_PARAM)
	if path.strip_edges().is_empty():
		return _err("path is required", ErrorCodes.INVALID_PATH)
	var normalized := normalize(path)
	if not normalized.begins_with("res://") and not normalized.begins_with("user://"):
		return _err("only res:// and user:// paths are allowed", ErrorCodes.INVALID_PATH)
	# Reject parent segments, but collapse harmless lexical dot segments before
	# checking protected prefixes so aliases cannot bypass the write boundary.
	var path_without_scheme := normalized.trim_prefix("res://").trim_prefix("user://")
	for segment in path_without_scheme.split("/", false):
		if segment == "..":
			return _err("path traversal is not allowed", ErrorCodes.INVALID_PATH)
	if normalized.ends_with("://") and mode != "read":
		return _err("path must name a resource", ErrorCodes.INVALID_PATH)
	if mode == "write" or mode == "delete":
		var path_for_comparison := normalized
		if OS.get_name() == "Windows":
			path_for_comparison = path_for_comparison.to_lower()
		for prefix in BLOCKED_WRITE_PREFIXES:
			var prefix_for_comparison: String = (
				prefix.to_lower() if OS.get_name() == "Windows" else prefix
			)
			if (
				path_for_comparison == prefix_for_comparison.trim_suffix("/")
				or path_for_comparison.begins_with(prefix_for_comparison)
			):
				return _err("path is protected: " + normalized, ErrorCodes.PERMISSION_DENIED, 403)
	return {"ok": true, "path": normalized}


static func normalize(path: String) -> String:
	var p := path.strip_edges().replace("\\", "/")
	var scheme := ""
	if p.begins_with("res://"):
		scheme = "res://"
	elif p.begins_with("user://"):
		scheme = "user://"
	if not scheme.is_empty():
		var segments := PackedStringArray()
		for segment in p.trim_prefix(scheme).split("/", false):
			if segment.is_empty() or segment == ".":
				continue
			segments.append(segment)
		return scheme + "/".join(segments)
	if p.begins_with("/") or (p.length() >= 2 and p[1] == ":"):
		return p
	# Any other URI/scheme-like input is invalid rather than a relative path.
	if p.contains(":"):
		return p
	return "res://" + p.trim_prefix("/")


static func _err(message: String, code: String, status: int = 400) -> Dictionary:
	return {"ok": false, "error": message, "code": code, "status": status}
