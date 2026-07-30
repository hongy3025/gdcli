@tool
class_name GdApiNetworkService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const TargetGuard := preload("res://addons/gdapi/runtime/services/network_target_guard.gd")


static func validate(body: Dictionary, policy: Dictionary) -> Dictionary:
	var url := String(body.get("url", ""))
	var parts := url.split("://", true, 1)
	if parts.size() != 2:
		return _error(ErrorCodes.INVALID_PARAM, "URL scheme is required")
	var authority := parts[1].split("/", true, 1)[0]
	if authority.contains("@") or url.contains("#"):
		return _error(ErrorCodes.INVALID_PARAM, "URL credentials and fragments are not allowed")
	var host := authority
	var port := 443 if parts[0].to_lower() == "https" else 80
	if authority.contains(":"):
		var fields := authority.rsplit(":", true, 1)
		host = fields[0]
		port = int(fields[1])
	var target := TargetGuard.authorize(url, policy)
	if not target.ok:
		return target
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
		"url": target.url,
		"scheme": target.scheme,
		"host": target.host,
		"port": target.port,
		"addresses": target.addresses,
		"method": method,
		"timeout_ms": timeout,
		"max_response_bytes": cap,
		"max_redirects": clampi(int(policy.get("max_redirects", 0)), 0, 5),
		"redirect_policy": policy.duplicate(true),
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
	var request_headers: PackedStringArray = []
	for key in spec.headers:
		request_headers.append("%s: %s" % [key, spec.headers[key]])
	var state := {
		"node": node,
		"response": response,
		"done": false,
		"redirects": 0,
		"visited": {spec.url: true},
		"headers": request_headers,
		"method": HTTPClient.METHOD_GET if spec.method == "GET" else HTTPClient.METHOD_HEAD,
		"body": spec.body,
		"spec": spec,
	}
	node.request_completed.connect(
		func(result, response_code, headers, body):
			if state.done:
				return
			if (
				result == HTTPRequest.RESULT_SUCCESS
				and response_code >= 300
				and response_code < 400
			):
				var location := _header_value(headers, "location")
				if location.is_empty() or int(state.redirects) >= int(spec.max_redirects):
					state.done = true
					state["outcome"] = {
						"ok": false,
						"code": ErrorCodes.CONFLICT,
						"summary": "redirect limit reached"
					}
					response.error("redirect limit reached", ErrorCodes.CONFLICT, 409)
					node.queue_free()
					return
				var target := TargetGuard.authorize(location, spec.redirect_policy)
				if not target.ok or state.visited.has(target.url):
					state.done = true
					state["outcome"] = {
						"ok": false,
						"code": target.code if not target.ok else ErrorCodes.CONFLICT,
						"summary": "redirect target rejected"
					}
					response.error(
						"redirect target rejected",
						String(state.outcome.code),
						ErrorCodes.http_status(String(state.outcome.code))
					)
					node.queue_free()
					return
				state.redirects += 1
				state.visited[target.url] = true
				var redirect_error := node.request(
					target.url, state.headers, state.method, state.body
				)
				if redirect_error != OK:
					state.done = true
					state["outcome"] = {
						"ok": false,
						"code": ErrorCodes.GODOT_ERROR,
						"summary": "redirect request could not start"
					}
					response.error("redirect request could not start", ErrorCodes.GODOT_ERROR, 500)
					node.queue_free()
				return
			state.done = true
			if result != HTTPRequest.RESULT_SUCCESS:
				state["outcome"] = {
					"ok": false,
					"code":
					(
						ErrorCodes.TIMEOUT
						if result == HTTPRequest.RESULT_TIMEOUT
						else ErrorCodes.GODOT_ERROR
					),
					"summary": "HTTP request failed"
				}
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
				state["outcome"] = {"ok": true, "code": "", "summary": "HTTP request completed"}
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
	var err := node.request(spec.url, request_headers, state.method, spec.body)
	if err != OK:
		node.queue_free()
		return _error(ErrorCodes.GODOT_ERROR, "HTTP request could not start")
	return {"ok": true, "state": state}


static func _header_value(headers: PackedStringArray, wanted: String) -> String:
	for header in headers:
		var separator := header.find(":")
		if separator > 0 and header.left(separator).strip_edges().to_lower() == wanted:
			return header.substr(separator + 1).strip_edges()
	return ""


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
