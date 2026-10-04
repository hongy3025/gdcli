## HTTP 响应封装类
##
## 提供构建和发送 HTTP 响应的流畅接口（Fluent Interface）。
## 支持设置状态码、响应头、JSON 数据、纯文本、文件响应和错误响应。
## 通过链式调用简化响应构建过程，确保每个请求只发送一次响应。

@tool
class_name GdApiResponse
extends RefCounted

const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

## 已完成的 JSON 响应体与独立请求审计所有者。
var payload: Dictionary = {}
var audit_context: Dictionary = {}
var request_control
var _operation_committed := false
var _committed_payload: Dictionary = {}

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
## @param control HTTP 层提供的统一取消所有者（非 HTTP 调用须显式传 null）
func _init(server, request_id: int, control) -> void:
	_server = server
	_request_id = request_id
	request_control = control
	_headers["Content-Type"] = "application/json; charset=utf-8"


## Router 在校验 body 之前绑定，异步 handler 继续持有同一所有者。
func bind_audit(route: String, mutation: bool) -> void:
	audit_context = {"route": route, "mutation": mutation, "completed": false}


## 异步危险操作在响应完成前提供摘要，不再在延迟 task finish 后补写。
func audit_summary(safety: String, summary: Dictionary) -> void:
	AuditLog.record("", safety, summary, true, "", audit_context)


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
	if _sent:
		return
	payload = data
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
		error("cannot read file: " + path, "godot_error", 500)
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
func error(
	msg: String, code: String = "error", status: int = 400, details: Dictionary = {}
) -> void:
	_status = status
	var body := {"error": msg, "code": code}
	if not details.is_empty():
		body["details"] = details
	json(body)


## 查询响应是否已经发送。
##
## 异步 route adapter 使用该查询和本地 completion 标志共同防止迟到回调重复回复。
func is_sent() -> bool:
	return _sent


func remaining_ms() -> int:
	return 0 if request_control == null else int(request_control.remaining_ms())


func cancellation_reason() -> String:
	if request_control == null:
		return ""
	return String(request_control.cancellation_reason())


func mark_operation_committed(data: Dictionary) -> void:
	_operation_committed = true
	_committed_payload = data


## Record a deferred failure even when a disconnected client cannot receive the response.
func complete_audit_failure(message: String, code: String, status: int) -> void:
	AuditLog.complete_request(audit_context, {"error": message, "code": code}, status)


## 内部发送方法
##
## 实际发送响应到客户端，确保每个请求只发送一次响应。
## @param body 响应体字节数据
func _send(body: PackedByteArray) -> void:
	if _sent:
		push_warning("GdApiResponse: already sent")
		return
	var reason := "" if _operation_committed else cancellation_reason()
	if not reason.is_empty():
		_status = 504 if reason == "timeout" else 409
		payload = {
			"error": "handler timeout" if reason == "timeout" else "request cancelled: " + reason,
			"code": "timeout" if reason == "timeout" else "conflict"
		}
		body = JSON.stringify(payload).to_utf8_buffer()
	_sent = true

	var headers_dict: Dictionary[String, Variant] = {}
	for key in _headers:
		headers_dict[key] = _headers[key]

	var response_accepted: bool = _server.send_response(_request_id, _status, headers_dict, body)
	if response_accepted:
		AuditLog.complete_request(audit_context, payload, _status)
	elif _operation_committed:
		AuditLog.complete_request(audit_context, _committed_payload, _status)


## 根据文件扩展名获取 MIME 类型
##
## @param ext 文件扩展名（小写）
## @return 对应的 MIME 类型字符串
func _get_mime_type(ext: String) -> String:
	var mime_types := {
		"png": "image/png",
		"jpg": "image/jpeg",
		"jpeg": "image/jpeg",
		"gif": "image/gif",
		"svg": "image/svg+xml",
		"json": "application/json",
		"txt": "text/plain",
		"html": "text/html",
		"css": "text/css",
		"js": "application/javascript",
		"gdshader": "text/plain",
		"shader": "text/plain",
		"tscn": "text/plain",
		"tres": "text/plain",
		"gd": "text/plain",
	}
	return mime_types.get(ext, "application/octet-stream")
