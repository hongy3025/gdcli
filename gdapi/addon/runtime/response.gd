@tool
class_name GdApiResponse
extends RefCounted

var _status: int = 200
var _headers: Dictionary = {}
var _server
var _request_id: int
var _sent: bool = false

func _init(server, request_id: int) -> void:
	_server = server
	_request_id = request_id
	_headers["Content-Type"] = "application/json; charset=utf-8"

func status(code: int) -> GdApiResponse:
	_status = code
	return self

func set(key: String, value: String) -> GdApiResponse:
	_headers[key] = value
	return self

func type(content_type: String) -> GdApiResponse:
	_headers["Content-Type"] = content_type
	return self

func json(data: Dictionary) -> void:
	_send(JSON.stringify(data).to_utf8_buffer())

func send(content: String) -> void:
	if not _headers.has("Content-Type"):
		_headers["Content-Type"] = "text/plain; charset=utf-8"
	_send(content.to_utf8_buffer())

func file(path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		error("file not found: " + path, "not_found", 404)
		return
	
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		error("cannot read file: " + path, "read_error", 500)
		return
	
	var buffer := f.get_buffer(f.get_length())
	f.close()
	
	var ext := path.get_extension().to_lower()
	var mime := _get_mime_type(ext)
	_headers["Content-Type"] = mime
	_send(buffer)

func error(msg: String, code: String = "error", status: int = 400, details: Dictionary = {}) -> void:
	_status = status
	var body := {"error": msg, "code": code}
	if not details.is_empty():
		body["details"] = details
	json(body)

func _send(body: PackedByteArray) -> void:
	if _sent:
		push_warning("GdApiResponse: already sent")
		return
	_sent = true
	
	var headers_dict := {}
	for key in _headers:
		headers_dict[key] = _headers[key]
	
	_server.send_response(_request_id, _status, headers_dict, body)

func _get_mime_type(ext: String) -> String:
	match ext:
		"png": return "image/png"
		"jpg", "jpeg": return "image/jpeg"
		"gif": return "image/gif"
		"svg": return "image/svg+xml"
		"json": return "application/json"
		"txt": return "text/plain"
		"html": return "text/html"
		"css": return "text/css"
		"js": return "application/javascript"
		"gdshader", "shader": return "text/plain"
		"tscn", "tres", "gd": return "text/plain"
		_: return "application/octet-stream"
