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
## HTTP 层专用：非 POST 请求被 router 直接拒绝（不属于 route 业务错误码）。
const METHOD_NOT_ALLOWED := "method_not_allowed"

const HTTP_STATUS := {
	MISSING_PARAM: 400,
	INVALID_PARAM: 400,
	INVALID_PATH: 400,
	PERMISSION_DENIED: 403,
	UNSAFE_OPERATION: 403,
	NOT_FOUND: 404,
	CONFLICT: 409,
	TIMEOUT: 408,
	NOT_SUPPORTED: 501,
	GODOT_ERROR: 500,
	METHOD_NOT_ALLOWED: 405,
}


static func http_status(code: String) -> int:
	return int(HTTP_STATUS.get(code, 500))
