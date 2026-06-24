@tool
class_name GdApiRequest
extends RefCounted

var method: String
var path: String
var headers: Dictionary
var body: Dictionary
var query: String
var params: Dictionary
var raw_body: PackedByteArray

func _init(req_dict: Dictionary) -> void:
	method = req_dict.get("method", "POST")
	path = req_dict.get("path", "/")
	headers = req_dict.get("headers", {})
	raw_body = req_dict.get("body", PackedByteArray())
	
	var parts := path.split("?", true, 1)
	if parts.size() > 1:
		path = parts[0]
		query = parts[1]
	
	if raw_body.size() > 0:
		var text := raw_body.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			body = parsed

func get_body(key: String, default: Variant = null) -> Variant:
	return body.get(key, default)

func get_header(name: String) -> String:
	return headers.get(name.to_lower(), "")

func has_body(key: String) -> bool:
	return body.has(key)

func get_query(key: String, default: String = "") -> String:
	for param in query.split("&"):
		var kv := param.split("=", true, 1)
		if kv.size() == 2 and kv[0] == key:
			return kv[1]
	return default

func is_json() -> bool:
	var ct := get_header("content-type")
	return ct.begins_with("application/json")

func client_ip() -> String:
	return headers.get("x-forwarded-for", headers.get("remote-addr", "127.0.0.1"))
