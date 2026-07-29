@tool
class_name GdApiNetworkService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


static func validate(body: Dictionary, policy: Dictionary) -> Dictionary:
	var url := String(body.get("url", ""))
	var parts := url.split("://", true, 1)
	if parts.size() != 2 or parts[0].to_lower() not in policy.get("schemes", []):
		return _error(ErrorCodes.PERMISSION_DENIED, "URL scheme is not allowed")
	var authority := parts[1].split("/", true, 1)[0]
	if authority.contains("@") or url.contains("#"):
		return _error(ErrorCodes.INVALID_PARAM, "URL credentials and fragments are not allowed")
	var host := authority
	var port := 443 if parts[0].to_lower() == "https" else 80
	if authority.contains(":"):
		var fields := authority.rsplit(":", true, 1)
		host = fields[0]
		port = int(fields[1])
	var hosts: Array = policy.get("hosts", [])
	var allowed := hosts.has(host)
	for item in hosts:
		if (
			String(item).begins_with("*.")
			and (
				host == String(item).trim_prefix("*.")
				or host.ends_with("." + String(item).trim_prefix("*."))
			)
		):
			allowed = true
	if not allowed or not policy.get("ports", []).has(port):
		return _error(ErrorCodes.PERMISSION_DENIED, "network target is not allowed")
	if not bool(policy.get("allow_private", false)) and _is_private_host(host):
		return _error(ErrorCodes.PERMISSION_DENIED, "private network target is not allowed")
	var method := String(body.get("method", "GET")).to_upper()
	if method not in ["GET", "HEAD"]:
		return _error(ErrorCodes.PERMISSION_DENIED, "HTTP method is not allowed")
	var timeout := int(body.get("timeout_ms", 5000))
	var cap := int(body.get("max_response_bytes", 1048576))
	if (
		timeout <= 0
		or timeout > int(policy.get("max_timeout_ms", 0))
		or cap <= 0
		or cap > int(policy.get("max_response_bytes", 0))
	):
		return _error(ErrorCodes.INVALID_PARAM, "request limits exceed policy")
	return {
		"ok": true,
		"url": url,
		"method": method,
		"timeout_ms": timeout,
		"max_response_bytes": cap,
		"headers": body.get("headers", {}),
		"body": String(body.get("body", ""))
	}


static func start(spec: Dictionary, response: GdApiResponse) -> Dictionary:
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin == null:
		return _error(ErrorCodes.GODOT_ERROR, "plugin is unavailable")
	var node := HTTPRequest.new()
	node.timeout = float(spec.timeout_ms) / 1000.0
	node.body_size_limit = spec.max_response_bytes
	node.max_redirects = 0
	plugin.add_child(node)
	var state := {"node": node, "response": response, "done": false}
	node.request_completed.connect(
		func(result, response_code, headers, body):
			if state.done:
				return
			state.done = true
			if result != HTTPRequest.RESULT_SUCCESS:
				response.error(
					"HTTP request failed",
					(
						ErrorCodes.TIMEOUT
						if result == HTTPRequest.RESULT_TIMEOUT
						else ErrorCodes.GODOT_ERROR
					),
					408 if result == HTTPRequest.RESULT_TIMEOUT else 500
				)
			else:
				var context := HashingContext.new()
				context.start(HashingContext.HASH_SHA256)
				context.update(body)
				var digest := context.finish().hex_encode()
				var encoded := Marshalls.raw_to_base64(body)
				response.json(
					{
						"ok": true,
						"status": response_code,
						"headers": headers,
						"body_base64": encoded,
						"size": body.size(),
						"sha256": digest,
						"redirects": 0,
						"undoable": false
					}
				)
			node.queue_free()
	)
	var headers: PackedStringArray = []
	for key in spec.headers:
		headers.append("%s: %s" % [key, spec.headers[key]])
	var method := HTTPClient.METHOD_GET if spec.method == "GET" else HTTPClient.METHOD_HEAD
	var err := node.request(spec.url, headers, method, spec.body)
	if err != OK:
		node.queue_free()
		return _error(ErrorCodes.GODOT_ERROR, "HTTP request could not start")
	return {"ok": true, "state": state}


static func _is_private_host(host: String) -> bool:
	return (
		host == "localhost"
		or host == "127.0.0.1"
		or host == "::1"
		or host.begins_with("10.")
		or host.begins_with("192.168.")
		or host.begins_with("172.16.")
	)


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
