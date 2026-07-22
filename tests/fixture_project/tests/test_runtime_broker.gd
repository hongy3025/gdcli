## GdApiRuntimeBroker 单元测试
##
## 测试运行期 broker 的状态机、pending 回调、disconnect/timeout 清理。
## 不依赖真实 Godot 调试器，使用 SceneTreeTimer + 内存发件箱/收件箱。

@tool
extends SceneTree

const Broker := preload("res://addons/gdapi/runtime/runtime_broker.gd")

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

var passed := 0
var failed := 0

# 模拟的发送回调：把消息推进 mailbox,供测试断言。
# 真实路径中这就是 EditorDebuggerSession.send_message 包成的 Callable。
var sent: Array = []

func _init() -> void:
	print("Running GdApiRuntimeBroker tests...\n")

	test_initial_state_is_stopped()
	test_attach_transitions_to_connecting()
	test_first_request_transitions_to_connected()
	test_detach_completes_pending_with_conflict()
	test_detach_is_idempotent()
	test_status_returns_pending_count()
	test_request_timeout_completes_with_timeout()
	test_unknown_reply_does_not_crash()
	test_multiple_requests_then_detach()
	test_request_after_detach_returns_immediately()

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

func _make_send() -> Callable:
	return func(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
		return true

func _wait(_frames: int) -> void:
	# SceneTree 中 signals/timer 推进需要 process_frame。
	# 测试里我们沿用 process_frame 信号挂起,直到 _test_tick 触发。
	await process_frame

func test_initial_state_is_stopped() -> void:
	var b: RefCounted = Broker.new()
	assert_eq(b.status().state, "stopped", "initial state stopped")
	assert_eq(b.status().pending, 0, "no pending")
	assert_eq(b.status().protocol_version, Protocol.VERSION, "protocol version")

func test_attach_transitions_to_connecting() -> void:
	var b: RefCounted = Broker.new()
	b.attach(7, _make_send())
	assert_eq(b.status().state, "connecting", "state after attach")
	assert_eq(b.status().session_id, 7, "session id remembered")

func test_first_request_transitions_to_connected() -> void:
	var b: RefCounted = Broker.new()
	b.attach(7, _make_send())
	var received: Array = []
	b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	# 状态变为 connected；并向 runtime 发出一条 hello/probe request。
	assert_eq(b.status().state, "connected", "state after first request")
	assert_eq(sent.size(), 1, "one outgoing message")
	assert_eq(sent[0]["op"], "runtime/status", "op echoed")
	# 完成第一条 pending。
	var reply := Protocol.reply(sent[0].id, true, {"protocol_version": 1})
	b.receive(reply)
	await _wait(2)
	assert_eq(received.size(), 1, "callback fired")
	assert_eq(received[0]["ok"], true, "reply ok")
	assert_eq(b.status().pending, 0, "pending zeroed")

func test_detach_completes_pending_with_conflict() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	b.detach("game stopped")
	assert_eq(b.status().state, "stopped", "state back to stopped")
	assert_eq(b.status().pending, 0, "no pending after detach")
	assert_eq(received.size(), 1, "callback fired exactly once")
	assert_eq(received[0]["code"], "conflict", "failure code")
	assert_eq(received[0]["ok"], false, "failure ok=false")

func test_detach_is_idempotent() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	b.detach("first")
	b.detach("second")
	b.detach("third")
	assert_eq(b.status().state, "stopped", "still stopped")

func test_status_returns_pending_count() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	b.request("op/a", {}, 5000, func(_reply: Dictionary) -> void: pass)
	b.request("op/b", {}, 5000, func(_reply: Dictionary) -> void: pass)
	b.request("op/c", {}, 5000, func(_reply: Dictionary) -> void: pass)
	assert_eq(b.status().pending, 3, "three pending")

func test_request_timeout_completes_with_timeout() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	b.request("slow", {}, 5, func(reply: Dictionary) -> void:
		received.append(reply))
	# 让 timer 自然到期。
	var deadline_msec: int = Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < deadline_msec:
		await process_frame
	# 推动一次 broker 的 _process（如果 broker 用了 timer）。
	for i in range(3):
		await process_frame
	assert_eq(received.size(), 1, "timeout callback fired")
	assert_eq(received[0]["code"], "timeout", "timeout code")
	assert_eq(b.status().pending, 0, "pending cleared")

func test_unknown_reply_does_not_crash() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	b.receive({"version": 1, "id": 9999, "kind": "reply", "ok": true, "result": {}})
	assert_eq(b.status().pending, 0, "still zero pending")

func test_multiple_requests_then_detach() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	for i in range(5):
		var op: String = "op/%d" % i
		b.request(op, {}, 5000, func(reply: Dictionary) -> void:
			received.append(reply))
	assert_eq(b.status().pending, 5, "five pending")
	b.detach("shutdown")
	assert_eq(received.size(), 5, "all five completed")
	for reply in received:
		assert_eq(reply["code"], "conflict", "all conflict")

func test_request_after_detach_returns_immediately() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	b.detach("shutdown")
	var received: Array = []
	b.request("op/after", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	assert_eq(received.size(), 1, "immediate callback")
	assert_eq(received[0]["code"], "conflict", "conflict because detached")
