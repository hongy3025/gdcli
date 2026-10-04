@tool
class_name GdApiNetworkTargetGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ALLOWED_SCHEMES := ["http", "https"]


## 结构校验 URL：仅 http/https；禁止内嵌 credentials/fragment/控制字符；host/port 合法。
## 不做 host/port 白名单与私网检查（开发期工具，Bearer token 已构成访问控制）。
static func authorize(url: String) -> Dictionary:
	if url.contains("#") or url.contains("@") or url.contains("\n") or url.contains("\r"):
		return _error(
			ErrorCodes.INVALID_PARAM, "URL credentials, fragments, and controls are not allowed"
		)
	var parts := url.split("://", true, 1)
	if parts.size() != 2:
		return _error(ErrorCodes.INVALID_PARAM, "URL scheme is required")
	var scheme := parts[0].to_lower()
	if not ALLOWED_SCHEMES.has(scheme):
		return _error(ErrorCodes.PERMISSION_DENIED, "URL scheme is not allowed")
	var authority := parts[1].split("/", true, 1)[0].split("?", true, 1)[0]
	# HTTPRequest 只接受带路径的 URL：authority-only 的 http://host?x=1 必须补成 /?x=1，
	# 否则 request() 直接失败（"HTTP request could not start"）。
	var remainder := parts[1].substr(authority.length())
	var normalized := (
		"%s://%s%s"
		% [scheme, authority, remainder if remainder.begins_with("/") else "/" + remainder]
	)
	var host := authority
	var port := 443 if scheme == "https" else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return _error(ErrorCodes.INVALID_PARAM, "invalid IPv6 host")
		host = authority.substr(1, close - 1)
		if close + 1 < authority.length():
			port = int(authority.substr(close + 2))
	elif authority.count(":") == 1:
		var fields := authority.rsplit(":", true, 1)
		host = fields[0]
		port = int(fields[1])
	if host.is_empty() or port < 1 or port > 65535:
		return _error(ErrorCodes.INVALID_PARAM, "invalid host or port")
	return {"ok": true, "url": normalized, "scheme": scheme, "host": host, "port": port}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
