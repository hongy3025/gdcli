@tool
class_name GdApiNetworkService
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const TargetGuard := preload("res://addons/gdapi/runtime/services/network_target_guard.gd")

const DEFAULT_TIMEOUT_MS := 30_000
const MAX_TIMEOUT_MS := 60_000
const DEFAULT_MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_REDIRECTS := 5


static func validate(body: Dictionary) -> Dictionary:
	var url := String(body.get("url", ""))
	var target := TargetGuard.authorize(url)
	if not target.ok:
		return target
	var method := String(body.get("method", "GET")).to_upper()
	if method not in ["GET", "HEAD"]:
		return _error(ErrorCodes.PERMISSION_DENIED, "HTTP method is not allowed")
	var timeout := int(body.get("timeout_ms", DEFAULT_TIMEOUT_MS))
	var cap := int(body.get("max_response_bytes", DEFAULT_MAX_RESPONSE_BYTES))
	if timeout <= 0 or timeout > MAX_TIMEOUT_MS:
		return _error(ErrorCodes.INVALID_PARAM, "timeout_ms must be in 1..60000")
	if cap <= 0 or cap > MAX_RESPONSE_BYTES:
		return _error(ErrorCodes.INVALID_PARAM, "max_response_bytes must be in 1..4194304")
	return {
		"ok": true,
		"url": target.url,
		"scheme": target.scheme,
		"host": target.host,
		"canonical_host": target.canonical_host,
		"port": target.port,
		"method": method,
		"timeout_ms": timeout,
		"max_response_bytes": cap,
		"max_redirects": clampi(int(body.get("max_redirects", MAX_REDIRECTS)), 0, MAX_REDIRECTS),
		"headers": body.get("headers", {}),
		"body": String(body.get("body", ""))
	}


static func start(spec: Dictionary, response: GdApiResponse) -> Dictionary:
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin == null:
		return _error(ErrorCodes.GODOT_ERROR, "plugin is unavailable")
	var node := HTTPRequest.new()
	node.timeout = float(spec.timeout_ms) / 1000.0
	node.max_redirects = 0
	node.body_size_limit = spec.max_response_bytes
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
		"current_url": spec.url,
		"current_target": spec,
		"headers": request_headers,
		"method": HTTPClient.METHOD_GET if spec.method == "GET" else HTTPClient.METHOD_HEAD,
		"body": spec.body,
		"spec": spec,
	}
	node.request_completed.connect(
		func(result, response_code, headers, body):
			if state.done:
				return
			var forced_truncated: bool = (
				int(result) == int(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED)
			)
			if forced_truncated:
				result = HTTPRequest.RESULT_SUCCESS
			var is_redirect = response_code >= 300 and response_code < 400 and response_code != 304
			if is_redirect:
				result = HTTPRequest.RESULT_SUCCESS
			elif result != HTTPRequest.RESULT_SUCCESS:
				is_redirect = false
			if result == HTTPRequest.RESULT_SUCCESS and is_redirect:
				var location := _resolve_redirect_url(
					String(state.current_url), _header_value(headers, "location")
				)
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
				var target := TargetGuard.authorize(location)
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
				if not _same_origin(state.current_target, target):
					state.headers = _without_credentials(state.headers)
				state.current_target = target
				state.redirects += 1
				state.visited[target.url] = true
				state.current_url = target.url
				# Reuse this node for the next hop; cancellation here is not task cancellation.
				node.cancel_request()
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
				var truncated := forced_truncated
				if body.size() > spec.max_response_bytes:
					body = body.slice(0, spec.max_response_bytes)
					truncated = true
				var context := HashingContext.new()
				context.start(HashingContext.HASH_SHA256)
				if not body.is_empty():
					context.update(body)
				var digest := context.finish().hex_encode()
				var encoded := "" if body.is_empty() else Marshalls.raw_to_base64(body)
				response.json(
					{
						"ok": true,
						"status": response_code,
						"headers": headers,
						"body_base64": encoded,
						"size": body.size(),
						"sha256": digest,
						"redirects": state.redirects,
						"truncated": truncated,
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


static func _same_origin(left: Dictionary, right: Dictionary) -> bool:
	return (
		left.scheme == right.scheme
		and (
			String(left.get("canonical_host", left.host))
			== String(right.get("canonical_host", right.host))
		)
		and left.port == right.port
	)


static func cancel(state: Dictionary) -> void:
	if state.is_empty() or bool(state.get("done", false)):
		return
	var node: HTTPRequest = state.get("node")
	state.clear()
	state["done"] = true
	if is_instance_valid(node):
		node.cancel_request()
		node.queue_free()


static func _without_credentials(headers: PackedStringArray) -> PackedStringArray:
	var safe: PackedStringArray = []
	for header in headers:
		var name := header.get_slice(":", 0).strip_edges().to_lower().replace("_", "-")
		if name in ["authorization", "proxy-authorization", "cookie", "cookie2", "host"]:
			continue
		var compact := name.replace("-", "")
		var sensitive := false
		for marker in ["auth", "token", "secret", "credential", "password", "passwd", "apikey"]:
			if compact.contains(marker):
				sensitive = true
				break
		if not sensitive:
			safe.append(header)
	return safe


static func _header_value(headers: PackedStringArray, wanted: String) -> String:
	for header in headers:
		var separator := header.find(":")
		if separator > 0 and header.left(separator).strip_edges().to_lower() == wanted:
			return header.substr(separator + 1).strip_edges()
	return ""


static func _resolve_redirect_url(current_url: String, location: String) -> String:
	var target := location.strip_edges()
	if target.is_empty() or target.contains("#"):
		return ""
	if (
		target.contains("://")
		and target.find("://") > 0
		and target.substr(0, target.find("://")).is_valid_identifier()
	):
		return target
	var scheme_end := current_url.find("://")
	if scheme_end < 0:
		return ""
	var scheme := current_url.left(scheme_end)
	var authority_start := scheme_end + 3
	var authority_end := current_url.length()
	for delimiter in ["/", "?"]:
		var found := current_url.find(delimiter, authority_start)
		if found >= 0:
			authority_end = mini(authority_end, found)
	var authority := current_url.substr(authority_start, authority_end - authority_start)
	if target.begins_with("//"):
		return "%s:%s" % [scheme, target]
	var base := current_url.substr(authority_end)
	var query_index := base.find("?")
	var base_path := base if query_index < 0 else base.left(query_index)
	if base_path.is_empty():
		base_path = "/"
	var target_path := target
	var target_query := ""
	var target_query_index := target.find("?")
	if target_query_index >= 0:
		target_path = target.left(target_query_index)
		target_query = target.substr(target_query_index)
	if target.begins_with("?"):
		return "%s://%s%s%s" % [scheme, authority, base_path, target]
	if target.begins_with("/"):
		return "%s://%s%s%s" % [scheme, authority, _remove_dot_segments(target_path), target_query]
	var directory_end := base_path.rfind("/")
	var directory := "/" if directory_end < 0 else base_path.left(directory_end + 1)
	return (
		"%s://%s%s%s"
		% [scheme, authority, _remove_dot_segments(directory + target_path), target_query]
	)


static func _remove_dot_segments(path: String) -> String:
	var absolute := path.begins_with("/")
	var trailing := path.ends_with("/") or path.ends_with("/.") or path.ends_with("/..")
	var segments: Array[String] = []
	var path_segments := path.split("/", true)
	for index in range(path_segments.size()):
		var segment := path_segments[index]
		if absolute and index == 0:
			continue
		if segment == ".":
			continue
		if segment == "..":
			if not segments.is_empty():
				segments.pop_back()
		else:
			segments.append(segment)
	var normalized := ("/" if absolute else "") + "/".join(segments)
	if trailing and not normalized.ends_with("/"):
		normalized += "/"
	return normalized if not normalized.is_empty() else "/"


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
