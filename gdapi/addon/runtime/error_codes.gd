@tool
class_name GdApiErrorCodes
extends RefCounted

const MISSING_PARAM := "missing_param"
const INVALID_PARAM := "invalid_param"
const INVALID_PATH := "invalid_path"
const NOT_FOUND := "not_found"
const CONFLICT := "conflict"
const NOT_SUPPORTED := "not_supported"
const PERMISSION_DENIED := "permission_denied"
const UNSAFE_OPERATION := "unsafe_operation"
const TIMEOUT := "timeout"
const GODOT_ERROR := "godot_error"

static func require_force(res: GdApiResponse, force: bool, operation: String) -> bool:
	if force:
		return true
	res.error(operation + " requires force:true", UNSAFE_OPERATION, 403)
	return false
