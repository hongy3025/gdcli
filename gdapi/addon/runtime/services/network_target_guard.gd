@tool
class_name GdApiNetworkTargetGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


static func authorize(
	url: String, policy: Dictionary, resolver: Callable = Callable()
) -> Dictionary:
	if url.contains("#") or url.contains("@") or url.contains("\n") or url.contains("\r"):
		return _error(
			ErrorCodes.INVALID_PARAM, "URL credentials, fragments, and controls are not allowed"
		)
	var parts := url.split("://", true, 1)
	if parts.size() != 2:
		return _error(ErrorCodes.INVALID_PARAM, "URL scheme is required")
	var scheme := parts[0].to_lower()
	if not policy.get("schemes", []).has(scheme):
		return _error(ErrorCodes.PERMISSION_DENIED, "URL scheme is not allowed")
	var authority := parts[1].split("/", true, 1)[0]
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
	var allowed := policy.get("hosts", []).has(host)
	for item in policy.get("hosts", []):
		var pattern := String(item)
		if pattern.begins_with("*.") and host.ends_with("." + pattern.trim_prefix("*.")):
			allowed = true
	if not allowed or not policy.get("ports", []).has(port):
		return _error(ErrorCodes.PERMISSION_DENIED, "network target is not allowed")
	var addresses: Array = []
	if resolver.is_valid():
		var resolved: Variant = resolver.call(host)
		if typeof(resolved) == TYPE_ARRAY or typeof(resolved) == TYPE_PACKED_STRING_ARRAY:
			addresses.assign(resolved)
	else:
		addresses.assign(IP.resolve_hostname_addresses(host, IP.TYPE_ANY))
	if addresses.is_empty() and IP.is_valid_ip_address(host):
		addresses.append(host)
	if addresses.is_empty():
		return _error(ErrorCodes.PERMISSION_DENIED, "host could not be resolved")
	addresses = _normalize_addresses(addresses)
	if not bool(policy.get("allow_private", false)):
		for address in addresses:
			if not is_public_address(String(address)):
				return _error(ErrorCodes.PERMISSION_DENIED, "private network target is not allowed")
	return {
		"ok": true, "url": url, "scheme": scheme, "host": host, "port": port, "addresses": addresses
	}


static func is_public_address(address: String) -> bool:
	var value := address.to_lower().trim_prefix("[").trim_suffix("]")
	if value.begins_with("::ffff:"):
		return is_public_address(value.trim_prefix("::ffff:"))
	if value.contains("."):
		var parts := value.split(".")
		if parts.size() != 4:
			return false
		var first := int(parts[0])
		var second := int(parts[1])
		return (
			first > 0
			and first < 224
			and not first == 10
			and not first == 127
			and not (first == 169 and second == 254)
			and not (first == 172 and second >= 16 and second <= 31)
			and not (first == 192 and second == 168)
			and not (first == 192 and second == 0)
			and not (first == 198 and (second == 18 or second == 19 or second == 51))
		)
	if (
		value == "::"
		or value == "::1"
		or value.begins_with("fc")
		or value.begins_with("fd")
		or value.begins_with("fe8")
		or value.begins_with("fe9")
		or value.begins_with("fea")
		or value.begins_with("feb")
		or value.begins_with("ff")
		or value.begins_with("2001:db8")
	):
		return false
	return IP.is_valid_ip_address(value)


static func _normalize_addresses(addresses: Array) -> Array:
	var unique: Dictionary = {}
	for address in addresses:
		unique[String(address).to_lower()] = true
	var result: Array = unique.keys()
	result.sort()
	return result


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
