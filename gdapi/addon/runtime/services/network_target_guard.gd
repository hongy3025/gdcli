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
			if authority[close + 1] != ":":
				return _error(ErrorCodes.INVALID_PARAM, "invalid URL port")
			var port_text := authority.substr(close + 2)
			if not port_text.is_valid_int():
				return _error(ErrorCodes.INVALID_PARAM, "invalid URL port")
			port = int(port_text)
	elif authority.count(":") == 1:
		var fields := authority.rsplit(":", true, 1)
		host = fields[0]
		if not fields[1].is_valid_int():
			return _error(ErrorCodes.INVALID_PARAM, "invalid URL port")
		port = int(fields[1])
	if host.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "URL host is required")
	if port <= 0 or port > 65535:
		return _error(ErrorCodes.INVALID_PARAM, "URL port must be in 1..65535")
	if host.contains(":"):
		var canonical_host := _canonical_ipv6(host)
		if canonical_host.is_empty():
			return _error(ErrorCodes.INVALID_PARAM, "invalid IPv6 host")
		return {
			"ok": true,
			"url": normalized,
			"scheme": scheme,
			"host": host,
			"canonical_host": canonical_host,
			"port": port
		}
	return {
		"ok": true,
		"url": normalized,
		"scheme": scheme,
		"host": host,
		"canonical_host": host.to_lower(),
		"port": port
	}


static func _canonical_ipv6(host: String) -> String:
	host = host.to_lower()
	if host.contains("."):
		var last_colon := host.rfind(":")
		if last_colon < 0:
			return ""
		var octets := host.substr(last_colon + 1).split(".")
		if octets.size() != 4:
			return ""
		var bytes: Array[int] = []
		for octet in octets:
			if not octet.is_valid_int():
				return ""
			var value := int(octet)
			if value < 0 or value > 255:
				return ""
			bytes.append(value)
		var first_word := (bytes[0] << 8) | bytes[1]
		var second_word := (bytes[2] << 8) | bytes[3]
		host = (
			host.left(last_colon + 1)
			+ String.num_int64(first_word, 16)
			+ ":"
			+ String.num_int64(second_word, 16)
		)
	var halves := host.split("::", true, 1)
	if halves.size() > 2:
		return ""
	var left: Array = [] if halves[0].is_empty() else halves[0].split(":")
	var right: Array = [] if halves.size() == 1 or halves[1].is_empty() else halves[1].split(":")
	var groups: Array = []
	for part in left + right:
		if part.is_empty() or part.length() > 4:
			return ""
		for character in part:
			if not "0123456789abcdef".contains(character):
				return ""
		groups.append(part.hex_to_int())
	if (halves.size() == 1 and groups.size() != 8) or (halves.size() == 2 and groups.size() >= 8):
		return ""
	var expanded: Array = []
	for part in left:
		expanded.append(part.hex_to_int())
	if halves.size() == 2:
		for _index in range(8 - groups.size()):
			expanded.append(0)
	for part in right:
		expanded.append(part.hex_to_int())
	if expanded.size() != 8:
		return ""
	var canonical := ""
	for group in expanded:
		if not canonical.is_empty():
			canonical += ":"
		canonical += String.num_int64(group, 16)
	return canonical


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
