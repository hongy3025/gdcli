## GdApiRuntimeProtocol 单元测试
##
## 测试运行时协议消息的构造和验证：
## - request(id, op, payload) 构造合法消息
## - validate_message 对版本/ID/kind/op/大小做边界校验
## - 拒绝 eval/process-run/network/http_request 等保留 op

@tool
extends SceneTree

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeProtocol tests...\n")

	test_request_message_shape()
	test_validate_message_accepts_valid_request()
	test_validate_message_rejects_wrong_version()
	test_validate_message_rejects_non_dict()
	test_validate_message_rejects_non_int_id()
	test_validate_message_rejects_zero_id()
	test_validate_message_rejects_unknown_kind()
	test_validate_message_rejects_missing_op()
	test_validate_message_rejects_eval_op()
	test_validate_message_rejects_process_run_op()
	test_validate_message_rejects_network_http_request_op()
	test_validate_message_rejects_oversized_payload()
	test_validate_message_accepts_reply()
	test_validate_message_accepts_event()
	test_request_default_payload_empty_dict()
	test_generation_metadata_is_preserved()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	if failed > 0:
		quit(1)
	else:
		quit(0)

func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func assert_false(value: bool, context: String = "") -> void:
	assert_eq(value, false, context)

func test_request_message_shape() -> void:
	var msg: Dictionary = Protocol.request(7, "runtime/status", {})
	assert_eq(msg.get("version"), 1, "version")
	assert_eq(msg.get("id"), 7, "id")
	assert_eq(msg.get("kind"), "request", "kind")
	assert_eq(msg.get("op"), "runtime/status", "op")
	assert_eq(msg.get("payload"), {}, "payload")

func test_validate_message_accepts_valid_request() -> void:
	var msg := Protocol.request(1, "runtime/status", {})
	assert_true(Protocol.validate_message(msg).ok, "valid request")

func test_validate_message_rejects_wrong_version() -> void:
	var msg := {"version": 2, "id": 1, "kind": "request", "op": "x", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "not_supported", "version mismatch")

func test_validate_message_rejects_non_dict() -> void:
	assert_eq(Protocol.validate_message("not a dict").code, "invalid_param", "string input")
	assert_eq(Protocol.validate_message(42).code, "invalid_param", "int input")
	assert_eq(Protocol.validate_message(null).code, "invalid_param", "null input")
	assert_eq(Protocol.validate_message([1, 2, 3]).code, "invalid_param", "array input")

func test_validate_message_rejects_non_int_id() -> void:
	var msg := {"version": 1, "id": "7", "kind": "request", "op": "x", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "invalid_param", "string id")

func test_validate_message_rejects_zero_id() -> void:
	var msg := {"version": 1, "id": 0, "kind": "request", "op": "x", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "invalid_param", "zero id")

func test_validate_message_rejects_unknown_kind() -> void:
	var msg := {"version": 1, "id": 1, "kind": "banana", "op": "x", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "invalid_param", "unknown kind")

func test_validate_message_rejects_missing_op() -> void:
	var msg := {"version": 1, "id": 1, "kind": "request", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "invalid_param", "missing op")

func test_validate_message_rejects_eval_op() -> void:
	var msg := {"version": 1, "id": 1, "kind": "request", "op": "eval", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "permission_denied", "eval denied")

func test_validate_message_rejects_process_run_op() -> void:
	var msg := {"version": 1, "id": 1, "kind": "request", "op": "process/run", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "permission_denied", "process/run denied")

func test_validate_message_rejects_network_http_request_op() -> void:
	var msg := {"version": 1, "id": 1, "kind": "request", "op": "network/http_request", "payload": {}}
	assert_eq(Protocol.validate_message(msg).code, "permission_denied", "network denied")

func test_validate_message_rejects_oversized_payload() -> void:
	var big_value := ""
	for i in range(1024):
		big_value += "a"
	# Build a payload whose JSON serialization exceeds 4 MiB after stringify.
	var arr: Array = []
	for i in range((4 * 1024 * 1024) / 1024 + 8):
		arr.append(big_value)
	var msg := {"version": 1, "id": 1, "kind": "request", "op": "x", "payload": {"big": arr}}
	var verdict := Protocol.validate_message(msg)
	assert_eq(verdict.code, "invalid_param", "oversize denied")

func test_validate_message_accepts_reply() -> void:
	var msg := {"version": 1, "id": 3, "kind": "reply", "ok": true, "result": {}}
	assert_true(Protocol.validate_message(msg).ok, "valid reply")

func test_validate_message_accepts_event() -> void:
	var msg := {"version": 1, "id": 4, "kind": "event", "result": {}}
	assert_true(Protocol.validate_message(msg).ok, "valid event")

func test_request_default_payload_empty_dict() -> void:
	# request tolerates a missing/empty payload argument.
	var msg1: Dictionary = Protocol.request(2, "runtime/scene/tree")
	var msg2: Dictionary = Protocol.request(2, "runtime/scene/tree", {})
	assert_eq(msg1.get("payload"), {}, "default empty payload")
	assert_eq(msg2.get("payload"), {}, "explicit empty payload")

func test_generation_metadata_is_preserved() -> void:
	var request := Protocol.request(8, "runtime/status", {}, "generation-a")
	var reply := Protocol.reply(8, true, {"ready": true}, "", "", "generation-a")
	var hello := Protocol.event(0, "hello", {
		"protocol_version": Protocol.VERSION,
		"generation": "generation-a",
		"pid": 123,
		"started_at": 1.5,
		"transport": "file",
	})
	assert_eq(request.get("generation"), "generation-a", "request generation")
	assert_eq(reply.get("generation"), "generation-a", "reply generation")
	assert_eq(hello.get("result", {}).get("generation"), "generation-a", "event generation")
	assert_true(Protocol.validate_message(request).ok, "generation request remains v1-valid")
	assert_true(Protocol.validate_message(reply).ok, "generation reply remains v1-valid")
	assert_true(Protocol.validate_message(hello).ok, "generation event remains v1-valid")
