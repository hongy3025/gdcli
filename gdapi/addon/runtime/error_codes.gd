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
}


static func http_status(code: String) -> int:
	return int(HTTP_STATUS.get(code, 500))


## 过渡 stub: Task 5 删除 force 闸门后保留此函数以维持 uid/ 等
## 未在 Task 5 清理的调用方继续加载；调用永远返回 true,实际授权
## 决策下放到下游(M6+) 重新设计。
static func require_force(_res: GdApiResponse, _force: bool, _operation: String) -> bool:
	return true
