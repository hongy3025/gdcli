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
	test_detach_clears_transport_before_reentrant_callback()
	test_detach_is_idempotent()
	test_status_returns_pending_count()
	test_request_timeout_completes_with_timeout()
	test_unknown_reply_does_not_crash()
	test_invalid_reply_does_not_complete_pending_request()
	test_oversized_request_is_rejected_without_sending()
	test_oversized_reply_completes_once_without_waiting_for_timeout()
	test_broker_timeout_is_bounded_to_route_grace_limit()
	test_multiple_requests_then_detach()
	test_request_after_detach_returns_immediately()
	test_transport_field_initial_none()
	test_attach_file_transport_sets_transport_file()
	test_engine_debugger_sender_keeps_priority_over_file_transport()
	test_engine_disconnect_falls_back_to_file_transport()
	test_both_transports_detach_fail_pending_once()
	test_set_active_transport_keeps_priority_selection()
	test_detach_file_transport_returns_to_none()
	test_begin_generation_replaces_pending_and_binds_requests()
	test_begin_generation_clears_transport_before_reentrant_callback()
	test_new_session_clears_old_transport_before_reentrant_callback()
	test_stale_generation_reply_is_ignored()
	test_stale_transport_generation_cannot_attach()

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

func test_detach_clears_transport_before_reentrant_callback() -> void:
	var b: RefCounted = Broker.new()
	var transport_sent: Array = []
	var callback_replies: Array = []
	var reentrant_replies: Array = []
	b.attach(3, func(message: Dictionary) -> bool:
		transport_sent.append(message.duplicate(true))
		return true
	)
	b.request("op/original", {}, 5000, func(reply: Dictionary) -> void:
		callback_replies.append(reply)
		b.request("op/reentrant", {}, 5000, func(reentrant_reply: Dictionary) -> void:
			reentrant_replies.append(reentrant_reply)
		)
	)
	assert_eq(transport_sent.size(), 1, "original detach request is sent once")
	b.detach("shutdown")
	assert_eq(callback_replies.size(), 1, "detach completes original callback once")
	assert_eq(reentrant_replies.size(), 1, "detach reentrant request fails synchronously")
	if reentrant_replies.size() == 1:
		assert_eq(reentrant_replies[0].get("code", ""), "conflict",
			"detach reentrant request sees stopped broker")
	assert_eq(transport_sent.size(), 1, "detach reentry cannot use old sender")
	assert_eq(b.status().pending, 0, "detach reentry leaves no pending request")
	assert_eq(b.status().state, "stopped", "detach callback observes stopped state")
	assert_eq(b.status().transport, "none", "detach callback observes no transport")

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
	# broker 的 timeout 由 transport 每帧显式推进。
	b.tick(Time.get_ticks_msec() + 100)
	assert_eq(received.size(), 1, "timeout callback fired")
	assert_eq(received[0]["code"], "timeout", "timeout code")
	assert_eq(b.status().pending, 0, "pending cleared")

func test_unknown_reply_does_not_crash() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	b.receive({"version": 1, "id": 9999, "kind": "reply", "ok": true, "result": {}})
	assert_eq(b.status().pending, 0, "still zero pending")

func test_invalid_reply_does_not_complete_pending_request() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	var id: int = b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	b.receive({"version": 2, "id": id, "kind": "reply", "ok": true})
	assert_eq(received.size(), 0, "invalid reply does not invoke callback")
	assert_eq(b.status().pending, 1, "invalid reply leaves request pending")
	b.receive(Protocol.reply(id, true, {"ready": true}))
	assert_eq(received.size(), 1, "valid reply completes request")
	assert_eq(b.status().pending, 0, "valid reply clears pending")

func test_oversized_request_is_rejected_without_sending() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var sent_before: int = sent.size()
	var received: Array = []
	b.request("runtime/status", {"body": "x".repeat(Protocol.MAX_MESSAGE_BYTES)}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	assert_eq(received.size(), 1, "oversized request invokes callback")
	assert_eq(received[0].get("code", ""), "invalid_param", "oversized request preserves invalid_param")
	assert_eq(sent.size(), sent_before, "oversized request is not sent")
	assert_eq(b.status().pending, 0, "oversized request does not enter pending")

func test_oversized_reply_completes_once_without_waiting_for_timeout() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	var id: int = b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	var oversized := Protocol.reply(id, true, {
		"blob": "x".repeat(Protocol.MAX_MESSAGE_BYTES),
	})
	b.receive(oversized)
	assert_eq(received.size(), 1, "oversized reply completes immediately")
	if received.size() == 1:
		assert_eq(received[0].get("code", ""), "invalid_param",
			"oversized reply preserves invalid_param")
	assert_eq(b.status().pending, 0, "oversized reply erases pending before callback")
	b.receive(Protocol.reply(id, true, {"late": true}))
	b.tick(Time.get_ticks_msec() + 100000)
	b.detach("late disconnect")
	assert_eq(received.size(), 1, "oversized reply path completes exactly once")

func test_broker_timeout_is_bounded_to_route_grace_limit() -> void:
	var b: RefCounted = Broker.new()
	b.attach(3, _make_send())
	var received: Array = []
	var started := Time.get_ticks_msec()
	b.request("runtime/status", {}, 999999, func(reply: Dictionary) -> void:
		received.append(reply))
	b.tick(started + 26001)
	assert_eq(received.size(), 1, "broker caps timeout at 26 seconds")
	if received.size() == 1:
		assert_eq(received[0].get("code", ""), "timeout", "bounded broker timeout code")
	assert_eq(b.status().pending, 0, "bounded broker timeout clears pending")

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

func test_transport_field_initial_none() -> void:
	var b: RefCounted = Broker.new()
	assert_eq(b.status().transport, "none", "initial transport is none")

func test_attach_file_transport_sets_transport_file() -> void:
	var b: RefCounted = Broker.new()
	var file_sent: Array = []
	var send := func(message: Dictionary) -> bool:
		file_sent.append(message.duplicate(true))
		return true
	b.attach_file_transport("abcdef12", send)
	assert_eq(b.status().transport, "file", "transport flips to file")
	assert_eq(b.status().state, "connected", "state directly to connected")
	# probe_id 是 hex,is_valid_int() 返回 false,broker 把 _session_id 留为 -1
	assert_eq(b.status().session_id, -1, "hex probe_id yields session_id -1")
	# 验证 sender 真的被设置成 file callable
	var received: Array = []
	b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	assert_eq(file_sent.size(), 1, "file transport sent the request")
	assert_eq(b.status().pending, 1, "request is pending")
	# detach_file_transport 清理
	b.detach_file_transport("test cleanup")
	assert_eq(b.status().transport, "none", "transport back to none after detach")
	assert_eq(b.status().state, "stopped", "state back to stopped after detach")
	assert_eq(b.status().pending, 0, "pending cleared after detach")

func test_engine_debugger_sender_keeps_priority_over_file_transport() -> void:
	var b: RefCounted = Broker.new()
	var engine_sent: Array = []
	var file_sent: Array = []
	b.attach(42, func(message: Dictionary) -> bool:
		engine_sent.append(message.duplicate(true))
		return true
	)
	b.mark_connected()
	b._set_active_transport("engine_debugger")
	b.attach_file_transport("file1234", func(message: Dictionary) -> bool:
		file_sent.append(message.duplicate(true))
		return true
	)
	b.request("runtime/status", {}, 5000, func(_reply: Dictionary) -> void: pass)
	assert_eq(engine_sent.size(), 1, "engine debugger sender retains priority")
	assert_eq(file_sent.size(), 0, "file sender is not used while engine debugger is connected")
	assert_eq(b.status().transport, "engine_debugger", "engine debugger remains active transport")
	assert_eq(b.status().session_id, 42, "engine debugger session id remains active")

func test_engine_disconnect_falls_back_to_file_transport() -> void:
	var b: RefCounted = Broker.new()
	var engine_sent: Array = []
	var file_sent: Array = []
	b.attach(42, func(message: Dictionary) -> bool:
		engine_sent.append(message.duplicate(true))
		return true
	)
	b.mark_connected()
	b.attach_file_transport("file1234", func(message: Dictionary) -> bool:
		file_sent.append(message.duplicate(true))
		return true
	)
	assert_eq(b.status().transport, "engine_debugger", "engine debugger starts active")

	assert_true(b.has_method("detach_engine_debugger"), "broker exposes explicit engine detach")
	if not b.has_method("detach_engine_debugger"):
		return
	b.call("detach_engine_debugger", "session cleared")
	assert_eq(b.status().transport, "file", "file transport becomes active after engine disconnect")

	b.request("runtime/status", {}, 5000, func(_reply: Dictionary) -> void: pass)
	assert_eq(engine_sent.size(), 0, "disconnected engine sender is not reused")
	assert_eq(file_sent.size(), 1, "file transport receives fallback request")

func test_both_transports_detach_fail_pending_once() -> void:
	var b: RefCounted = Broker.new()
	var received: Array = []
	b.attach(42, func(_message: Dictionary) -> bool:
		return true
	)
	b.mark_connected()
	b.attach_file_transport("file1234", func(_message: Dictionary) -> bool:
		return true
	)
	b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply)
	)
	assert_true(b.has_method("detach_engine_debugger"), "broker exposes explicit engine detach")
	if not b.has_method("detach_engine_debugger"):
		return
	b.call("detach_engine_debugger", "session cleared")
	assert_eq(received.size(), 0, "engine detach preserves pending while file fallback is active")
	b.detach_file_transport("file stopped")
	assert_eq(received.size(), 1, "last transport detach completes pending once")
	assert_eq(received[0]["code"], "conflict", "pending fails with conflict")
	b.detach("duplicate stop")
	assert_eq(received.size(), 1, "duplicate detach does not repeat callback")

func test_set_active_transport_keeps_priority_selection() -> void:
	var b: RefCounted = Broker.new()
	b.attach_file_transport("11223344", _make_send())
	assert_eq(b.status().transport, "file", "file after file transport")
	b._set_active_transport("engine_debugger")
	assert_eq(b.status().transport, "file", "unavailable engine cannot override file")

func test_detach_file_transport_returns_to_none() -> void:
	var b: RefCounted = Broker.new()
	b.attach_file_transport("aabbccdd", _make_send())
	# 在没有 attach EngineDebugger 的情况下 detach_file_transport 也应工作
	b.detach_file_transport("editor stopping")
	assert_eq(b.status().transport, "none", "transport none after file detach")
	assert_eq(b.status().state, "stopped", "state stopped after file detach")
	# 重复 detach 是 no-op,不应抛错
	b.detach_file_transport("again")
	assert_eq(b.status().state, "stopped", "still stopped")

func test_begin_generation_replaces_pending_and_binds_requests() -> void:
	var b: RefCounted = Broker.new()
	var received: Array = []
	b.attach(7, _make_send())
	b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	var generation_a: String = b.begin_generation()
	var generation_b: String = b.begin_generation()
	assert_true(not generation_a.is_empty(), "generation is non-empty")
	assert_true(generation_a != generation_b, "generations are unique")
	assert_eq(received.size(), 1, "restart fails old pending exactly once")
	assert_eq(b.status().pending, 0, "restart clears pending")
	b.attach(7, _make_send(), generation_b)
	b.begin_connect(generation_b)
	b.request("runtime/status", {}, 5000, func(_reply: Dictionary) -> void: pass)
	assert_eq(sent.back().get("generation"), generation_b, "request binds current generation")
	assert_eq(b.status().generation, generation_b, "status exposes current generation")

func test_begin_generation_clears_transport_before_reentrant_callback() -> void:
	var b: RefCounted = Broker.new()
	var transport_sent: Array = []
	var callback_replies: Array = []
	var reentrant_replies: Array = []
	b.attach(7, func(message: Dictionary) -> bool:
		transport_sent.append(message.duplicate(true))
		return true
	)
	b.request("op/original", {}, 5000, func(reply: Dictionary) -> void:
		callback_replies.append(reply)
		b.request("op/reentrant", {}, 5000, func(reentrant_reply: Dictionary) -> void:
			reentrant_replies.append(reentrant_reply)
		)
	)
	assert_eq(transport_sent.size(), 1, "original generation request is sent once")
	b.begin_generation()
	assert_eq(callback_replies.size(), 1, "generation replacement completes original callback")
	assert_eq(reentrant_replies.size(), 1, "generation reentrant request fails synchronously")
	if reentrant_replies.size() == 1:
		assert_eq(reentrant_replies[0].get("code", ""), "conflict",
			"generation reentrant request sees stopped broker")
	assert_eq(transport_sent.size(), 1, "generation reentry cannot use old sender")
	assert_eq(b.status().pending, 0, "generation reentry leaves no pending request")
	assert_eq(b.status().state, "stopped", "generation callback observes stopped state")
	assert_eq(b.status().transport, "none", "generation callback observes no transport")

func test_new_session_clears_old_transport_before_reentrant_callback() -> void:
	var b: RefCounted = Broker.new()
	var old_transport_sent: Array = []
	var new_transport_sent: Array = []
	var callback_replies: Array = []
	var reentrant_replies: Array = []
	b.attach(7, func(message: Dictionary) -> bool:
		old_transport_sent.append(message.duplicate(true))
		return true
	)
	b.request("op/original", {}, 5000, func(reply: Dictionary) -> void:
		callback_replies.append(reply)
		b.request("op/reentrant", {}, 5000, func(reentrant_reply: Dictionary) -> void:
			reentrant_replies.append(reentrant_reply)
		)
	)
	assert_eq(old_transport_sent.size(), 1, "old session request is sent once")
	b.attach(8, func(message: Dictionary) -> bool:
		new_transport_sent.append(message.duplicate(true))
		return true
	)
	assert_eq(callback_replies.size(), 1, "session replacement completes original callback")
	assert_eq(reentrant_replies.size(), 1, "session reentrant request fails synchronously")
	if reentrant_replies.size() == 1:
		assert_eq(reentrant_replies[0].get("code", ""), "conflict",
			"session reentrant request sees invalidated broker")
	assert_eq(old_transport_sent.size(), 1, "session reentry cannot use old sender")
	assert_eq(new_transport_sent.size(), 0, "session callback runs before new sender is bound")
	assert_eq(b.status().pending, 0, "session reentry leaves no pending request")
	assert_eq(b.status().state, "connecting", "new session is bound after callback cleanup")
	b.request("op/new-session", {}, 5000, func(_reply: Dictionary) -> void: pass)
	assert_eq(new_transport_sent.size(), 1, "subsequent request uses new session sender")

func test_stale_generation_reply_is_ignored() -> void:
	var b: RefCounted = Broker.new()
	var generation_a: String = b.begin_generation()
	var generation_b: String = b.begin_generation()
	b.begin_connect(generation_b)
	var received: Array = []
	var id: int = b.request("runtime/status", {}, 5000, func(reply: Dictionary) -> void:
		received.append(reply))
	b.receive(Protocol.reply(id, true, {"stale": true}, "", "", generation_a))
	assert_eq(received.size(), 0, "stale reply does not complete request")
	assert_eq(b.status().pending, 1, "stale reply leaves current pending")
	b.receive(Protocol.reply(id, true, {"current": true}, "", "", generation_b))
	assert_eq(received.size(), 1, "current reply completes request")
	assert_eq(received[0].get("generation"), generation_b, "current reply reaches callback")

func test_stale_transport_generation_cannot_attach() -> void:
	var b: RefCounted = Broker.new()
	var generation_a: String = b.begin_generation()
	var generation_b: String = b.begin_generation()
	assert_false(b.attach_file_transport("stale", _make_send(), generation_a),
		"stale file hello is rejected")
	assert_eq(b.status().transport, "none", "stale hello does not connect")
	assert_true(b.attach_file_transport("current", _make_send(), generation_b),
		"current file hello attaches")
	assert_eq(b.status().transport, "file", "current hello connects")
