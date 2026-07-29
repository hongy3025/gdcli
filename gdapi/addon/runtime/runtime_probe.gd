## Runtime probe — 在游戏进程内接收 broker 请求并返回 reply
##
## 作为 autoload 注入运行期进程。它通过 EngineDebugger.register_message_capture
## 接收编辑器发来的 protocol v1 request，调用对应 op 处理函数，把 reply 回送。
##
## 设计要点：
## - 与 broker 完全解耦：probe 不依赖 broker，只依赖 wire 格式；
## - 所有副作用 op（runtime/node/*、runtime/input/* 等）必须在 perform_* 中显式实现，
##   否则返回 not_supported；
## - 永远不应该调用 Expression、str2var、randstr、eval 或动态编译；
## - 每次收到非 hello 协议消息时记录到本地 ring buffer，供 runtime/log/read 使用；
## - hello 阶段推迟 gdapi/runtime_probe_hello_delay_ms 毫秒，方便 E2E 观测 connecting。
## - 文件 transport:非编辑器进程下总会创建并启动,与 EngineDebugger transport
##   并存(同时存在);EngineDebugger 抢到 hello 时把 broker._active_transport
##   置为 engine_debugger,headless 下 file transport 兜底。

@tool
extends Node

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")
const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")
const InputOps := preload("res://addons/gdapi/runtime/runtime_input_ops.gd")
const CaptureOps := preload("res://addons/gdapi/runtime/runtime_capture_ops.gd")
const RingBuffer := preload("res://addons/gdapi/runtime/runtime_ring_buffer.gd")
const FileTransport := preload("res://addons/gdapi/runtime/runtime_transport_file_probe.gd")
const DEBUGGER_CHANNEL_PREFIX := "gdapi"
const DEBUGGER_CHANNEL := "gdapi:protocol"
const DEBUGGER_CALLBACK_CHANNEL := "protocol"
const STANDARD_MONITORS := {
	"FPS": Performance.TIME_FPS,
	"PROCESS_TIME": Performance.TIME_PROCESS,
	"PHYSICS_TIME": Performance.TIME_PHYSICS_PROCESS,
	"OBJECT_COUNT": Performance.OBJECT_COUNT,
	"OBJECT_NODE_COUNT": Performance.OBJECT_NODE_COUNT,
	"OBJECT_RESOURCE_COUNT": Performance.OBJECT_RESOURCE_COUNT,
	"MEMORY_STATIC": Performance.MEMORY_STATIC,
	"MEMORY_STATIC_MAX": Performance.MEMORY_STATIC_MAX,
}

## hello 延迟：从 _ready 到第一条 hello 事件之间的毫秒数。
## 在项目设置中通过 gdapi/runtime_probe_hello_delay_ms 覆盖，默认 0。
var _hello_delay_ms: int = 0

## hello 阶段是否已经发送——只发一次
var _hello_sent: bool = false
var _engine_debugger_registered: bool = false

## 本地日志/错误 ring buffer,容量 2000 条
var _ring: RefCounted = RingBuffer.new(2000)

## 文件 transport 实例;非编辑器进程下 _ready() 中创建
var _file_transport: RefCounted = null
var file_transport_last_disconnect_abandoned: int:
	get:
		if _file_transport == null or not _file_transport.has_method("last_disconnect_abandoned_count"):
			return 0
		return int(_file_transport.last_disconnect_abandoned_count())
var file_transport_last_disconnect_remaining: int:
	get:
		if _file_transport == null or not _file_transport.has_method("last_disconnect_remaining_count"):
			return 0
		return int(_file_transport.last_disconnect_remaining_count())

## 容器,根据 _ready 时机,允许 hello 阶段被推迟
func _ready() -> void:
	if not OS.has_feature("debug"):
		# EngineDebugger 在 release 构建下也可能可用,但为了安全 default 跳过
		pass
	_hello_delay_ms = int(ProjectSettings.get_setting("gdapi/runtime_probe_hello_delay_ms", 0))
	if Engine.is_editor_hint():
		# Editor 进程不运行游戏,probe 仅在游戏进程里注册 capture
		return
	var force_file_transport := bool(ProjectSettings.get_setting(
		"gdapi/runtime_force_file_transport", false))
	if not force_file_transport:
		EngineDebugger.register_message_capture(DEBUGGER_CHANNEL_PREFIX, _on_runtime_capture)
		_engine_debugger_registered = true
	# 文件 transport:总在游戏进程里启动,与 EngineDebugger 并存。
	# EngineDebugger 在 headless 不可达时由 file transport 接管。
	_file_transport = FileTransport.new(_hello_delay_ms)
	_file_transport.set_request_handler(_handle_file_transport_request)
	_file_transport.start()
	if _hello_delay_ms <= 0:
		_send_hello()
	else:
		var t := get_tree().create_timer(_hello_delay_ms / 1000.0)
		t.timeout.connect(_on_hello_timer_timeout)

## 每帧推动 file transport(扫描 inbox、写 outbox、超时处理)
func _process(_dt: float) -> void:
	if _file_transport != null:
		_file_transport.tick(Time.get_ticks_msec())

## probe 退出时清理 file transport(删除自己的子目录)
func _exit_tree() -> void:
	if _engine_debugger_registered:
		EngineDebugger.unregister_message_capture(DEBUGGER_CHANNEL_PREFIX)
		_engine_debugger_registered = false
	if _file_transport != null:
		_file_transport.stop()

## file transport 收到 request 时调用;与 EngineDebugger capture 复用同一 _dispatch_async
##
## 协程 op(screenshot/assert/signal/sequence)在 await 后返回 reply,非协程 op 同步返回。
##
## @param req 协议 v1 request 字典
## @return 协议 v1 reply 字典或 awaitable result(交给 file transport 写 outbox)
func _handle_file_transport_request(req: Dictionary) -> Variant:
	var op: String = String(req.get("op", ""))
	var payload: Dictionary = req.get("payload", {})
	return await _dispatch_async(op, payload)

## 推迟到了 timer 触发时间后调用此函数
func _on_hello_timer_timeout() -> void:
	_send_hello()

## 注册 capture 后，runtime 接收的所有"编辑器->runtime"消息都先到达此函数
##
## 协议消息格式：args[0] 是 protocol v1 字典。
## 校验后再分发,可以向 reply 中加入业务字段。
##
## @return true 表示已处理, false 表示忽略
func _on_runtime_capture(channel: String, args: Array) -> bool:
	if channel != DEBUGGER_CALLBACK_CHANNEL:
		return false
	if typeof(args) != TYPE_ARRAY or args.size() < 1:
		return false
	var raw: Variant = args[0]
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	var verdict: Dictionary = Protocol.validate_message(raw)
	if not bool(verdict.get("ok", false)):
		return false
	var request_msg: Dictionary = raw
	if String(request_msg.get("kind", "")) != "request":
		return false
	if _file_transport != null:
		var active_generation := String(_file_transport.generation())
		var request_generation := String(request_msg.get("generation", ""))
		if not active_generation.is_empty() and request_generation != active_generation:
			return false
	_dispatch(request_msg)
	return true

## 按 op 字段把消息分发给对应实现
##
## 协程 op(screenshot/assert/signal/sequence)用 await 等待完成,再发 reply。
##
## @param request_msg 协议 v1 request 字典
func _dispatch(request_msg: Dictionary) -> void:
	var id: int = int(request_msg.get("id", 0))
	var op: String = String(request_msg.get("op", ""))
	var payload: Dictionary = request_msg.get("payload", {})
	var reply: Dictionary = await _dispatch_async(op, payload)
	var ok: bool = bool(reply.get("ok", false))
	var message: Dictionary = Protocol.reply(id, ok, reply.get("result", {}), String(reply.get("error", "")), String(reply.get("code", "")), String(request_msg.get("generation", "")))
	_send_message(message)

## 把 op 转成对应 reply
func _dispatch_async(op: String, payload: Dictionary) -> Dictionary:
	match op:
		"runtime/status":
			return _op_status(payload)
		"runtime/scene/tree":
			return NodeOps.tree(payload)
		"runtime/node/info":
			return NodeOps.info(payload)
		"runtime/node/get":
			return NodeOps.get_property(payload)
		"runtime/node/set":
			return NodeOps.set_property(payload)
		"runtime/node/call":
			return _op_node_call(payload)
		"runtime/node/find":
			return NodeOps.find(payload)
		"runtime/node/remove":
			return NodeOps.remove(payload)
		"runtime/node/reparent":
			return NodeOps.reparent(payload)
		"runtime/node/create":
			return NodeOps.create(payload)
		"runtime/node/duplicate":
			return NodeOps.duplicate_node(payload)
		"runtime/node/rename":
			return NodeOps.rename(payload)
		"runtime/input/key":
			return InputOps.key(payload)
		"runtime/input/mouse":
			return InputOps.mouse(payload)
		"runtime/input/gamepad":
			return InputOps.gamepad(payload)
		"runtime/input/touch":
			return InputOps.touch(payload)
		"runtime/input/action":
			return InputOps.action(payload)
		"runtime/input/sequence":
			return await InputOps.sequence(payload)
		"runtime/fixture/reset":
			return _fixture_reset(payload)
		"runtime/screenshot/viewport":
			return await CaptureOps.viewport(payload)
		"runtime/screenshot/camera":
			return await CaptureOps.camera(payload)
		"runtime/screenshot/frames":
			return await CaptureOps.frames(payload)
		"runtime/log/read":
			return _op_log_read(payload)
		"runtime/log/clear":
			return _op_log_clear(payload)
		"runtime/debug/performance":
			return _op_debug_performance(payload)
		"runtime/debug/monitors":
			return _op_debug_monitors(payload)
		"runtime/debug/errors":
			return _op_debug_errors(payload)
		"runtime/debug/breakpoints":
			return _op_debug_breakpoints(payload)
		"runtime/assert/condition":
			return await NodeOps.assert_condition(payload)
		"runtime/assert/node_exists":
			return await NodeOps.assert_node_exists(payload)
		"runtime/assert/property_equals":
			return await NodeOps.assert_property_equals(payload)
		"runtime/assert/signal_received":
			return await NodeOps.assert_signal_received(payload)
		"runtime/signal/connect":
			return NodeOps.signal_connect(payload)
		"runtime/signal/disconnect":
			return NodeOps.signal_disconnect(payload)
		"runtime/signal/emit":
			return NodeOps.signal_emit(payload)
		"runtime/signal/await":
			return await NodeOps.signal_await(payload)
		_:
			return {
				"ok": false,
				"code": "not_supported",
				"error": "unknown runtime op: %s" % op,
			}

## 实现 runtime/status
func _op_status(_payload: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"result": {
			"protocol_version": Protocol.VERSION,
			"editor_connected": true,
			"session_started_at": Time.get_unix_time_from_system(),
		},
	}

## 实现 runtime/log/read
func _op_log_read(payload: Dictionary) -> Dictionary:
	var after_cursor: int = int(payload.get("after_cursor", 0))
	var limit: int = int(payload.get("limit", 100))
	var cap: int = clampi(limit, 1, 500)
	var page: Dictionary = _ring.read(after_cursor, cap)
	return {"ok": true, "result": page}

## 实现 runtime/log/clear
func _op_log_clear(_payload: Dictionary) -> Dictionary:
	var info: Dictionary = _ring.clear()
	return {"ok": true, "result": info}

func _op_node_call(payload: Dictionary) -> Dictionary:
	var result := NodeOps.call_method(payload)
	if (
		bool(result.get("ok", false))
		and String(payload.get("node_path", "")) == "/root/RuntimeMain/ProbeTarget"
		and String(payload.get("method", "")) == "emit_known_logs"
	):
		record_log("info", "known-info", {"source": "runtime-fixture"})
		record_log("error", "known-error", {"source": "runtime-fixture"})
	return result

## Fixture-only fixed-semantics reset. This is intentionally not a public route:
## file harness requests use the single internal op, while EngineDebugger harness
## requests enter through ProbeTarget.reset_shared_fixture's explicit call allowlist.
func reset_shared_fixture() -> Dictionary:
	var root := get_tree().root.get_node_or_null("RuntimeMain")
	if root == null or not root.has_method("reset_fixture"):
		return {
			"ok": false,
			"changed": false,
			"undoable": false,
			"code": "not_supported",
			"error": "fixture reset is unavailable",
		}
	var result: Variant = root.call("reset_fixture")
	var ring_result: Dictionary = _ring.clear()
	if typeof(result) != TYPE_DICTIONARY:
		result = {"changed": true, "undoable": false}
	var normalized: Dictionary = result
	normalized["ok"] = true
	normalized["changed"] = bool(normalized.get("changed", true))
	normalized["undoable"] = false
	normalized["cleared_logs"] = int(ring_result.get("cleared", 0))
	return normalized

func _fixture_reset(payload: Dictionary) -> Dictionary:
	if not payload.is_empty():
		return {
			"ok": false,
			"code": "invalid_param",
			"error": "fixture reset does not accept payload fields",
		}
	var result := reset_shared_fixture()
	if not bool(result.get("ok", false)):
		return result
	var public_result := result.duplicate(true)
	public_result.erase("ok")
	return {"ok": true, "result": public_result}

## 实现 runtime/debug/performance
func _op_debug_performance(payload: Dictionary) -> Dictionary:
	var names: Array = payload.get("monitors", [])
	var values: Dictionary = {}
	if names.is_empty():
		for m in Performance.get_custom_monitor_names():
			values[m] = Performance.get_custom_monitor(m)
	else:
		for n in names:
			values[String(n)] = Performance.get_custom_monitor(String(n))
	return {"ok": true, "result": {"values": values}}

## 实现 runtime/debug/monitors（默认键集）
func _op_debug_monitors(_payload: Dictionary) -> Dictionary:
	var values: Dictionary = {}
	for key in STANDARD_MONITORS:
		values[key] = Performance.get_monitor(STANDARD_MONITORS[key])
	return {"ok": true, "result": {"monitors": values}}

## runtime/debug/errors：直接列出 stack frames via OS.get_error_count 或最近已知。
## v1 暂不实现详细回溯,返回 ok:true + empty list.
func _op_debug_errors(_payload: Dictionary) -> Dictionary:
	return {"ok": true, "result": {"items": []}}

## runtime/debug/breakpoints：v1 不支持编辑器端调试协议,直接 not_supported
func _op_debug_breakpoints(_payload: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"code": "not_supported",
		"error": "editor breakpoint mutation is unavailable in runtime probe v1",
	}

## 发送 hello 事件,告知编辑器 probe 已 ready
func _send_hello() -> void:
	if _hello_sent:
		return
	_hello_sent = true
	if not _engine_debugger_registered:
		return
	var hello: Dictionary = Protocol.event(0, "hello", {
		"protocol_version": Protocol.VERSION,
		"node": OS.get_processor_name(),
		"generation": String(_file_transport.generation()) if _file_transport != null else "",
		"pid": OS.get_process_id(),
		"started_at": Time.get_unix_time_from_system(),
	})
	hello["result"]["transport"] = "engine_debugger"
	_send_message(hello)

## Wire 发送:把 reply / event 通过 EngineDebugger 推到 editor
func _send_message(message: Dictionary) -> bool:
	if not _engine_debugger_registered or EngineDebugger == null or not EngineDebugger.is_active():
		return false
	EngineDebugger.send_message(DEBUGGER_CHANNEL, [message])
	return true

## 接收缓冲区(供 NodeOps 等内部使用)
func ring_buffer() -> RefCounted:
	return _ring

## 便利方法：probe 暴露的本地日志记录入口
func record_log(level: String, message: String, details: Dictionary = {}) -> void:
	_ring.append(level, message, details)
