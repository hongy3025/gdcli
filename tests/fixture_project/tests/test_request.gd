## GdApiRequest 单元测试
##
## 测试 HTTP 请求封装类的各个功能，包括：
## - JSON 请求体解析
## - 路径和查询参数分离
## - 请求头访问
## - 默认值处理
## - 边界条件和错误处理
##
## 运行方式：在 Godot 编辑器中执行此脚本

@tool
extends SceneTree

## 请求类预加载引用
var GdApiRequest = preload("res://addons/gdapi/runtime/request.gd")
## 测试通过计数
var passed := 0
## 测试失败计数
var failed := 0

## 初始化测试环境并运行所有测试
func _init() -> void:
	print("Running GdApiRequest tests...\n")

	# 运行所有测试用例
	test_json_body_parsed()
	test_raw_binary_body_stays_empty()
	test_empty_body_stays_empty()
	test_invalid_json_body_stays_empty()
	test_json_array_body_stays_empty()
	test_path_with_query_string_split()
	test_path_without_query_string()
	test_default_path_and_method()
	test_get_query_existing_key()
	test_get_query_missing_key_returns_default()
	test_get_query_empty_query()
	test_get_body_existing_key()
	test_get_body_missing_key_returns_default()
	test_has_body_existing_key()
	test_has_body_missing_key()
	test_is_json_true()
	test_is_json_false()
	test_is_json_no_header()
	test_client_ip_from_x_forwarded_for()
	test_client_ip_from_remote_addr()
	test_client_ip_default()
	test_get_header_case_insensitive()
	test_get_header_missing()
	test_raw_body_preserved()
	test_query_with_equals_in_value()

	# 输出测试结果
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	if failed > 0:
		quit(1)
	else:
		quit(0)

## 断言相等
##
## @param actual 实际值
## @param expected 期望值
## @param context 测试上下文描述
func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

## 断言为真
##
## @param value 要检查的布尔值
## @param context 测试上下文描述
func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

## 断言为假
##
## @param value 要检查的布尔值
## @param context 测试上下文描述
func assert_false(value: bool, context: String = "") -> void:
	assert_eq(value, false, context)

## 断言为空
##
## @param value 要检查的值
## @param context 测试上下文描述
func assert_null(value, context: String = "") -> void:
	if value == null:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected null, got '%s'" % [context, value])

## 测试 JSON 请求体解析
func test_json_body_parsed() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/api/test",
		"headers": {"content-type": "application/json"},
		"body": '{"key": "value", "num": 42}'.to_utf8_buffer()
	})
	assert_eq(req.body.get("key"), "value", "json body key")
	assert_eq(req.body.get("num"), 42, "json body num")

## 测试原始二进制请求体保持为空
func test_raw_binary_body_stays_empty() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/api/test",
		"headers": {"content-type": "application/octet-stream"},
		"body": PackedByteArray([0x00, 0xFF, 0x42])
	})
	assert_eq(req.body.size(), 0, "raw binary body empty")

## 测试空请求体保持为空
func test_empty_body_stays_empty() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/api/test",
		"headers": {}
	})
	assert_eq(req.body.size(), 0, "empty body stays empty")

## 测试无效 JSON 请求体保持为空
func test_invalid_json_body_stays_empty() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/api/test",
		"headers": {"content-type": "application/json"},
		"body": 'not valid json'.to_utf8_buffer()
	})
	assert_eq(req.body.size(), 0, "invalid json body empty")

## 测试 JSON 数组请求体保持为空（不是字典）
func test_json_array_body_stays_empty() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/api/test",
		"headers": {"content-type": "application/json"},
		"body": '[1, 2, 3]'.to_utf8_buffer()
	})
	assert_eq(req.body.size(), 0, "json array body stays empty (not dict)")

## 测试带查询字符串的路径分离
func test_path_with_query_string_split() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/api/test?foo=bar&baz=qux",
		"headers": {}
	})
	assert_eq(req.path, "/api/test", "path split from query")
	assert_eq(req.query, "foo=bar&baz=qux", "query extracted")

## 测试不带查询字符串的路径
func test_path_without_query_string() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/api/test",
		"headers": {}
	})
	assert_eq(req.path, "/api/test", "path without query")
	assert_eq(req.query, "", "empty query")

## 测试默认路径和方法
func test_default_path_and_method() -> void:
	var req = GdApiRequest.new({})
	assert_eq(req.method, "POST", "default method")
	assert_eq(req.path, "/", "default path")
	assert_eq(req.headers.size(), 0, "default headers empty")

## 测试获取存在的查询参数
func test_get_query_existing_key() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test?key=value&other=123",
		"headers": {}
	})
	assert_eq(req.get_query("key"), "value", "get_query key")
	assert_eq(req.get_query("other"), "123", "get_query other")

## 测试获取不存在的查询参数返回默认值
func test_get_query_missing_key_returns_default() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test?key=value",
		"headers": {}
	})
	assert_eq(req.get_query("missing"), "", "get_query missing default")
	assert_eq(req.get_query("missing", "fallback"), "fallback", "get_query missing custom default")

## 测试空查询字符串
func test_get_query_empty_query() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {}
	})
	assert_eq(req.get_query("key"), "", "get_query on empty query")

## 测试获取存在的请求体字段
func test_get_body_existing_key() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {},
		"body": '{"name": "test"}'.to_utf8_buffer()
	})
	assert_eq(req.get_body("name"), "test", "get_body existing")

## 测试获取不存在的请求体字段返回默认值
func test_get_body_missing_key_returns_default() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {},
		"body": '{"name": "test"}'.to_utf8_buffer()
	})
	assert_null(req.get_body("missing"), "get_body missing null")
	assert_eq(req.get_body("missing", "default"), "default", "get_body missing custom default")

## 测试检查存在的请求体字段
func test_has_body_existing_key() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {},
		"body": '{"key": "val"}'.to_utf8_buffer()
	})
	assert_true(req.has_body("key"), "has_body existing")

## 测试检查不存在的请求体字段
func test_has_body_missing_key() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {},
		"body": '{"key": "val"}'.to_utf8_buffer()
	})
	assert_false(req.has_body("missing"), "has_body missing")

## 测试 JSON 内容类型检测（真）
func test_is_json_true() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {"content-type": "application/json"},
		"body": '{}'.to_utf8_buffer()
	})
	assert_true(req.is_json(), "is_json true")

## 测试 JSON 内容类型检测（假）
func test_is_json_false() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {"content-type": "text/plain"},
		"body": 'hello'.to_utf8_buffer()
	})
	assert_false(req.is_json(), "is_json false")

## 测试无内容类型头时的 JSON 检测
func test_is_json_no_header() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {}
	})
	assert_false(req.is_json(), "is_json no header")

## 测试从 X-Forwarded-For 获取客户端 IP
func test_client_ip_from_x_forwarded_for() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {"x-forwarded-for": "192.168.1.1"}
	})
	assert_eq(req.client_ip(), "192.168.1.1", "client_ip x-forwarded-for")

## 测试从 remote-addr 获取客户端 IP
func test_client_ip_from_remote_addr() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {"remote-addr": "10.0.0.1"}
	})
	assert_eq(req.client_ip(), "10.0.0.1", "client_ip remote-addr")

## 测试默认客户端 IP
func test_client_ip_default() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {}
	})
	assert_eq(req.client_ip(), "127.0.0.1", "client_ip default")

## 测试请求头大小写不敏感
func test_get_header_case_insensitive() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {"content-type": "text/html"}
	})
	assert_eq(req.get_header("content-type"), "text/html", "get_header lowercase key")
	assert_eq(req.get_header("Content-Type"), "text/html", "get_header uppercase lookup")

## 测试获取不存在的请求头
func test_get_header_missing() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test",
		"headers": {}
	})
	assert_eq(req.get_header("missing"), "", "get_header missing")

## 测试原始请求体保持不变
func test_raw_body_preserved() -> void:
	var raw = PackedByteArray([0x48, 0x65, 0x6C, 0x6C, 0x6F])
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {},
		"body": raw
	})
	assert_eq(req.raw_body, raw, "raw_body preserved")

## 测试查询参数值中包含等号
func test_query_with_equals_in_value() -> void:
	var req = GdApiRequest.new({
		"method": "GET",
		"path": "/test?key=a=b",
		"headers": {}
	})
	assert_eq(req.get_query("key"), "a=b", "query value with equals")
