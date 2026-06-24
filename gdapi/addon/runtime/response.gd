## HTTP 响应封装类
##
## 提供构建和发送 HTTP 响应的流畅接口（Fluent Interface）。
## 支持设置状态码、响应头、JSON 数据、纯文本、文件响应和错误响应。
## 通过链式调用简化响应构建过程，确保每个请求只发送一次响应。

@tool
class_name GdApiResponse
extends RefCounted

## HTTP 响应状态码
var _status: int = 200
## 响应头字典
var _headers: Dictionary = {}
## 服务器实例引用，用于实际发送响应
var _server
## 关联的请求 ID
var _request_id: int
## 响应是否已发送标记，防止重复发送
var _sent: bool = false

## 初始化响应对象
##
## 设置服务器引用和请求 ID，并配置默认的 JSON 响应头。
## @param server HTTP 服务器实例
## @param request_id 关联的请求标识符
func _init(server, request_id: int) -> void:
	_server = server
	_request_id = request_id
	_headers["Content-Type"] = "application/json; charset=utf-8"

## 设置 HTTP 状态码
##
## @param code HTTP 状态码（如 200, 404, 500）
## @return 响应对象自身，支持链式调用
func status(code: int) -> GdApiResponse:
	_status = code
	return self

## 设置响应头
##
## @param key 头部名称
## @param value 头部值
## @return 响应对象自身，支持链式调用
func set_header(key: String, value: String) -> GdApiResponse:
	_headers[key] = value
	return self

## 设置 Content-Type 头部
##
## @param content_type MIME 类型字符串
## @return 响应对象自身，支持链式调用
func type(content_type: String) -> GdApiResponse:
	_headers["Content-Type"] = content_type
	return self

## 发送 JSON 响应
##
## 将字典数据序列化为 JSON 并发送。自动设置 Content-Type 为 application/json。
## @param data 要序列化的字典数据
func json(data: Dictionary) -> void:
	_send(JSON.stringify(data).to_utf8_buffer())

## 发送纯文本响应
##
## 发送纯文本内容，如果未设置 Content-Type 则自动设置为 text/plain。
## @param content 文本内容
func send(content: String) -> void:
	if not _headers.has("Content-Type"):
		_headers["Content-Type"] = "text/plain; charset=utf-8"
	_send(content.to_utf8_buffer())

## 发送文件响应
##
## 读取指定路径的文件并发送，自动根据扩展名设置 MIME 类型。
## 如果文件不存在或无法读取，会发送错误响应。
## @param path 文件路径（项目相对路径或绝对路径）
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

## 发送错误响应
##
## 构建标准格式的错误响应并发送。支持自定义错误代码和详细信息。
## @param msg 错误描述信息
## @param code 错误代码标识符（如 "not_found", "validation_error"）
## @param status HTTP 状态码
## @param details 额外的错误详情字典（可选）
func error(msg: String, code: String = "error", status: int = 400, details: Dictionary = {}) -> void:
	_status = status
	var body := {"error": msg, "code": code}
	if not details.is_empty():
		body["details"] = details
	json(body)

## 内部发送方法
##
## 实际发送响应到客户端，确保每个请求只发送一次响应。
## @param body 响应体字节数据
func _send(body: PackedByteArray) -> void:
	if _sent:
		push_warning("GdApiResponse: already sent")
		return
	_sent = true
	
	var headers_dict := {}
	for key in _headers:
		headers_dict[key] = _headers[key]
	
	_server.send_response(_request_id, _status, headers_dict, body)

## 根据文件扩展名获取 MIME 类型
##
## @param ext 文件扩展名（小写）
## @return 对应的 MIME 类型字符串
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
