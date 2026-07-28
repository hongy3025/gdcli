## 运行时 broker
##
## 编辑器侧的状态机与回调管家：跟踪 protocol_version、session_id，
## 持有所有 pending callback，按 id 派发 reply，统一处理 disconnect
## 与 timeout 清理。
##
## 设计原则：
## - 不直接依赖 EditorDebuggerSession / EngineDebugger，由 transport 注入 send；
## - pending 由整数 id 唯一索引，避免 op 字符串歧义；
## - detach 必须把所有 pending 同步失败回 callback，再清状态；
## - tick() 由外部每帧调用一次，可单测。
##
## Reply shape: {"ok":bool, "code"?:String, "error"?:String, ...}

@tool
class_name GdApiRuntimeBroker
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

## 三态机器：stopped / connecting / connected
var _state: String = "stopped"
## pending id -> {deadline_msec:int, callback:Callable, op:String}
var _pending: Dictionary = {}
## 当前 debugger session id;-1 表示无
var _session_id: int = -1
## 当前 send callable,由 transport 注入;Callable() 表示未连接
var _sender: Callable = Callable()
## 下一个请求 id;单调递增
var _next_id: int = 1
## 第一次 attach 的 unix 时间戳；用于 runtime/status 暴露的 session_started_at 字段。
## 多次重连（detach 后再 attach）保持首次值不变，方便客户端判定 session 重启。
var _session_started_at: float = 0.0
## 当前活跃 transport 标识:"engine_debugger" / "file" / "none"
## 默认 "none";EngineDebugger transport 在 hello 到达后置为 "engine_debugger";
## file transport 在 editor 侧 attach_file_transport() 调用后置为 "file"。
## 当前 file transport probe_id
var _file_probe_id: String = ""

## 当前 file transport send callable
var _file_sender: Callable = Callable()

var _active_transport: String = "none"

## 返回当前 broker 的可观测状态
##
## 含 session_id 让外部路由可以判定"是否同一会话";
## 含 pending 让 await/call 操作者能即时失败 pending;
## 含 broker_registered 表明 Engine meta 中是否已注册（始终为 true；外部路由
## 在 broker 缺席时直接返回 broker_registered=false，无需调用本方法）。
## @return 状态字典
func status() -> Dictionary:
	var pending_count: int = 0
	for _id in _pending:
		pending_count += 1
	return {
		"state": _state,
		"protocol_version": Protocol.VERSION,
		"session_id": _session_id,
		"pending": pending_count,
		"broker_registered": Engine.has_meta("gdapi_runtime_broker"),
		"session_started_at": _session_started_at,
		"transport": _active_transport,
	}
## 在切换 session（先 detach 再 attach）或第一次拉起游戏之前调用；
## 本方法会先把已有 pending 清掉再绑定新 session，避免悬挂。
##
## @param session_id EditorDebuggerSession.session_id
## @param send transport 注入的发送可调用对象（接收 Dictionary 返回 bool）
func attach(session_id: int, send: Callable) -> void:
	_prepare_new_session("previous session replaced")
	_session_id = session_id
	_sender = send
	_state = "connecting"
	if _session_started_at <= 0.0:
		_session_started_at = Time.get_unix_time_from_system()

## 把 broker 标记为 connecting 而不绑定 session
##
## 用于 project/run 已经发起但 debugger plugin 尚未回调之前；后续
## attach() 会刷新状态。
func begin_connect() -> void:
	if _state != "connected":
		_state = "connecting"

## 把 broker 标记为 connected（probe hello 已到达）
##
## 由 runtime debugger plugin 在收到 hello 事件时调用；
## 仅在状态机处于 connecting 时才推进到 connected。
func mark_connected() -> void:
	if _state == "connecting":
		_state = "connected"
## attach file transport(由 editor 侧文件 transport manager 调用)
##
## 把 send callable 切换到 file transport,并把状态推到 connected。
## EngineDebugger attach 在 hello 先到的情况下优先,这里仅在没 attach
## 过 EngineDebugger 时把状态推到 connected。
##
## @param probe_id probe 标识(全局唯一 hex)
## @param send file transport 注入的发送 callable
func attach_file_transport(probe_id: String, send: Callable) -> void:
	_file_probe_id = probe_id
	_file_sender = send
	_active_transport = "file"
	if _state == "stopped":
		_state = "connecting"
	_session_id = probe_id.to_int() if probe_id.is_valid_int() else -1
	_sender = send
	if _state == "connecting":
		_state = "connected"
	if _session_started_at <= 0.0:
		_session_started_at = Time.get_unix_time_from_system()

## detach file transport(editor 侧主动关闭时调用)
##
## 仅在当前活跃 transport 是 file 时清空 file 状态。
##
## @param reason 人类可读的关闭原因
func detach_file_transport(reason: String = "file transport detached") -> void:
	if _active_transport != "file":
		return
	_file_probe_id = ""
	_file_sender = Callable()
	_active_transport = "none"
	detach(reason)

## 由 transport 路径调用,显式切换活跃 transport 标识
##
## EngineDebugger hello 到达时切到 "engine_debugger",让上层能区分
## 当前生效的 transport。仅更新标识,不触碰 _sender。
##
## @param name transport 标识("engine_debugger" / "file" / "none")
func _set_active_transport(name: String) -> void:
	_active_transport = name


## 主动断开当前会话,清理所有 pending
##
## @param reason 人类可读的断开原因,会被写入失败 reply
func detach(reason: String = "runtime detached") -> void:
	if _state == "stopped" and _pending.is_empty():
		return
	var snapshot: Array = []
	for id in _pending.keys():
		snapshot.append([id, _pending[id].callback])
	_pending.clear()
	_session_id = -1
	_sender = Callable()
	_state = "stopped"
	for entry in snapshot:
		var cb: Callable = entry[1]
		var id: int = entry[0]
		var reply := {
			"ok": false,
			"code": "conflict",
			"error": reason if reason != "" else "runtime detached",
			"request_id": id,
		}
		if cb.is_valid():
			cb.call(reply)

## 发送一个请求,返回一个整数 id
##
## 当 broker 处于 stopped 状态时立即同步失败,不会进入 pending 也不发 send。
##
## @param op 协议 op 名,如 "runtime/status"
## @param payload 业务字段字典
## @param timeout_ms 超时毫秒,<=0 时默认 5000
## @param on_complete 收到 reply 或失败时调用的 callback(reply:Dictionary)
## @return 本次请求的整数 id(失败立即回调时返回的 id 也保留)
func request(op: String, payload: Dictionary, timeout_ms: int, on_complete: Callable) -> int:
	var id: int = _next_id
	_next_id += 1
	if _state == "stopped":
		if on_complete.is_valid():
			on_complete.call({
				"ok": false,
				"code": "conflict",
				"error": "runtime is not connected",
				"request_id": id,
			})
		return id
	var safe_payload: Dictionary = payload
	var message: Dictionary = Protocol.request(id, op, safe_payload)
	var verdict: Dictionary = Protocol.validate_message(message)
	if not bool(verdict.get("ok", false)):
		if on_complete.is_valid():
			on_complete.call({
				"ok": false,
				"code": verdict.get("code", "invalid_param"),
				"error": verdict.get("error", "invalid runtime message"),
				"request_id": id,
			})
		return id
	var bounded_timeout: int = timeout_ms if timeout_ms > 0 else 5000
	var deadline_msec: int = Time.get_ticks_msec() + bounded_timeout
	_pending[id] = {
		"deadline_msec": deadline_msec,
		"callback": on_complete,
		"op": op,
	}
	if _state == "connecting":
		_state = "connected"
	if not _sender.is_null():
		var ok: bool = bool(_sender.call(message))
		if not ok:
			_complete_with_failure(id, "conflict", "runtime transport refused the message")
	return id

## 处理一条来自 runtime 的回复（reply）或推送（event）
##
## @param message runtime 推过来的字典
func receive(message: Variant) -> void:
	if typeof(message) != TYPE_DICTIONARY:
		return
	var dict: Dictionary = message
	var kind: String = String(dict.get("kind", ""))
	if kind != "reply":
		# event 由 transport 决定怎么呈现，这里先接受但不回调 request。
		return
	var raw_id: Variant = dict.get("id", 0)
	if typeof(raw_id) != TYPE_INT:
		return
	var id: int = int(raw_id)
	if not _pending.has(id):
		return
	var entry: Dictionary = _pending[id]
	_pending.erase(id)
	var cb: Callable = entry.callback
	if cb.is_valid():
		cb.call(dict)

## 由 transport 周期性调用,清理已超时请求
##
## @param now_msec 当前毫秒时间戳
func tick(now_msec: int) -> void:
	var expired: Array = []
	for id in _pending.keys():
		var deadline: int = int(_pending[id].deadline_msec)
		if deadline <= now_msec:
			expired.append(id)
	for id in expired:
		_complete_with_failure(int(id), "timeout", "runtime request timed out")

## 把指定 id 的请求立即失败
##
## @param id 失败 id
## @param code 失败 code
## @param error 失败说明
func _complete_with_failure(id: int, code: String, error: String) -> void:
	if not _pending.has(id):
		return
	var entry: Dictionary = _pending[id]
	_pending.erase(id)
	var cb: Callable = entry.callback
	if cb.is_valid():
		cb.call({
			"ok": false,
			"code": code,
			"error": error,
			"request_id": id,
		})

## attach 前先把旧 pending 清理干净,避免重复 callback
func _prepare_new_session(reason: String) -> void:
	if _state == "stopped" and _pending.is_empty():
		return
	var snapshot: Array = []
	for id in _pending.keys():
		snapshot.append([id, _pending[id].callback])
	_pending.clear()
	for entry in snapshot:
		var cb: Callable = entry[1]
		if cb.is_valid():
			cb.call({
				"ok": false,
				"code": "conflict",
				"error": reason,
			})

## 暴露测试用的"instance" static 方法供 plugin/route 通过 Engine meta 访问
##
## 兼容未来在 EditorPlugin 中 _init 时挂 Broker.new() 然后存到 meta 的模式。
## @return meta 中的 broker 引用;若未注册则返回 null
static func instance() -> RefCounted:
	if Engine.has_meta("gdapi_runtime_broker"):
		var value: Variant = Engine.get_meta("gdapi_runtime_broker")
		if value != null:
			return value
	return null
