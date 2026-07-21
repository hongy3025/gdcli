## HTTP 请求封装类
##
## 封装从 HTTP 服务器接收到的请求数据，提供便捷的访问接口。
## 解析请求方法、路径、头部、查询参数和请求体（JSON 格式）。
## 支持路径参数提取，用于路由处理器获取动态路径片段。

@tool
class_name GdApiRequest
extends RefCounted

## HTTP 请求方法（GET, POST, PUT, DELETE 等）
var method: String
## 请求路径（不含查询参数）
var path: String
## 请求头字典，键为小写形式
var headers: Dictionary
## 解析后的 JSON 请求体
var body: Dictionary = {}
## 请求体解析错误信息（空字符串表示无错误）
var body_error: String = ""
## 查询字符串部分（? 后面的内容）
var query: String
## 路径参数字典，由路由系统填充（如 /users/:id 中的 id）
var params: Dictionary
## 原始请求体字节数据
var raw_body: PackedByteArray
## 插件引用，用于日志记录
var _plugin = null

## 初始化请求对象
##
## 从服务器传递的请求字典中解析各个字段。
## 自动分离路径和查询参数，并尝试解析 JSON 请求体。
## @param req_dict 服务器提供的原始请求数据字典
func _init(req_dict: Dictionary) -> void:
	method = req_dict.get("method", "POST")
	path = req_dict.get("path", "/")
	headers = req_dict.get("headers", {})
	raw_body = req_dict.get("body", PackedByteArray())
	
	# 分离路径和查询参数
	var parts := path.split("?", true, 1)
	if parts.size() > 1:
		path = parts[0]
		query = parts[1]
	
	# 尝试解析 JSON 请求体
	if raw_body.size() > 0:
		var content_type := get_header("content-type")
		if not content_type.is_empty() and not is_json():
			body_error = "content-type must be application/json"
			return
		var text := raw_body.get_string_from_utf8()
		var parser := JSON.new()
		if parser.parse(text) != OK:
			if not content_type.is_empty():
				body_error = "request body must be valid JSON"
			return
		if typeof(parser.data) != TYPE_DICTIONARY:
			body_error = "request body must be a JSON object"
			return
		body = parser.data

	# 获取插件引用用于日志
	if Engine.has_meta("gdapi_plugin"):
		_plugin = Engine.get_meta("gdapi_plugin")

## 获取请求体中的指定字段
##
## @param key 字段名
## @param default 字段不存在时的默认值
## @return 字段值或默认值
func get_body(key: String, default: Variant = null) -> Variant:
	return body.get(key, default)

## 获取请求头信息
##
## @param name 头部名称（不区分大小写）
## @return 头部值，不存在时返回空字符串
func get_header(name: String) -> String:
	return headers.get(name.to_lower(), "")

## 检查请求体是否包含指定字段
##
## @param key 要检查的字段名
## @return 字段是否存在
func has_body(key: String) -> bool:
	return body.has(key)

## 获取查询参数
##
## 从查询字符串中解析指定参数的值。
## @param key 参数名
## @param default 参数不存在时的默认值
## @return 参数值或默认值
func get_query(key: String, default: String = "") -> String:
	for param in query.split("&"):
		var kv := param.split("=", true, 1)
		if kv.size() == 2 and kv[0] == key:
			return kv[1]
	return default

## 检查请求是否为 JSON 格式
##
## 通过检查 Content-Type 头部判断请求体是否为 JSON 格式。
## @return 是否为 JSON 请求
func is_json() -> bool:
	var ct := get_header("content-type")
	if ct.is_empty():
		return false
	return ct.begins_with("application/json")

## 获取客户端 IP 地址
##
## 优先从 X-Forwarded-For 头部获取（支持代理），否则从 remote-addr 获取。
## @return 客户端 IP 地址字符串
func client_ip() -> String:
	return headers.get("x-forwarded-for", headers.get("remote-addr", "127.0.0.1"))

## 记录 debug 级别日志
## @param text 日志内容
func log_debug(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_DEBUG:
		_plugin.log_message(text, "debug")

## 记录 info 级别日志
## @param text 日志内容
func log_info(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_INFO:
		_plugin.log_message(text, "info")

## 记录 warn 级别日志
## @param text 日志内容
func log_warn(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_WARN:
		_plugin.log_message(text, "warn")

## 记录 error 级别日志
## @param text 日志内容
func log_error(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_ERROR:
		_plugin.log_message(text, "error")
