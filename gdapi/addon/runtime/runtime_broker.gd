## 运行时 broker
##
## 编辑器侧的状态机与回调管家：跟踪 protocol_version、session_id，
## 持有所有 pending callback，按 id 派发 reply，统一处理 disconnect
## 与 timeout 清理。
##
## 设计原则：
## - 不直接依赖 EditorDebuggerSession / EngineDebugger，由 transport 注入 send；
## - pending 由整数 id 唯一索引，避免 op 字符串歧义；
## - detach/session replacement 必须先清 pending 与 transport/state，再同步失败 callback；
## - tick() 由外部每帧调用一次，可单测。
##
## Reply shape: {"ok":bool, "code"?:String, "error"?:String, ...}

@tool
class_name GdApiRuntimeBroker
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")
const DEFAULT_REQUEST_TIMEOUT_MS := 5_000
const MAX_REQUEST_TIMEOUT_MS := 26_000

## 三态机器：stopped / connecting / connected
var _state: String = "stopped"
## pending id -> {deadline_msec:int, callback:Callable, op:String}
var _pending: Dictionary = {}
## 当前 debugger session id;-1 表示无
var _session_id: int = -1
## 当前被优先级选择的 send callable;Callable() 表示未连接
var _sender: Callable = Callable()
## EngineDebugger transport 的 send callable，与 file transport 独立保存。
var _engine_sender: Callable = Callable()
var _engine_connected: bool = false
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
## 当前运行世代；空字符串表示 legacy v1 测试/会话尚未协商世代。
var _generation: String = ""
var _file_generation: String = ""
var _engine_generation: String = ""
var _last_attach_accepted: bool = true

## 当前 file transport send callable
var _file_sender: Callable = Callable()
var _file_connected: bool = false

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
		"generation": _generation,
	}


## 在切换 session（先 detach 再 attach）或第一次拉起游戏之前调用；
## 本方法会先把已有 pending 清掉再绑定新 session，避免悬挂。
##
## @param session_id EditorDebuggerSession.session_id
## @param send transport 注入的发送可调用对象（接收 Dictionary 返回 bool）
func attach(session_id: int, send: Callable, generation: String = "") -> bool:
	if not _accept_generation(generation):
		_last_attach_accepted = false
		return false
	_last_attach_accepted = true
	_prepare_new_session("previous session replaced")
	_session_id = session_id
	_engine_sender = send
	_engine_generation = generation
	_engine_connected = false
	_sender = send
	_state = "connecting"
	if _session_started_at <= 0.0:
		_session_started_at = Time.get_unix_time_from_system()
	return true


## 把 broker 标记为 connecting 而不绑定 session
##
## 用于 project/run 已经发起但 debugger plugin 尚未回调之前；后续
## attach() 会刷新状态。
func begin_connect(generation: String = "") -> String:
	if generation.is_empty():
		generation = begin_generation()
	elif _generation.is_empty():
		_generation = generation
		_write_generation_marker()
	elif _generation != generation:
		return _generation
	if _state != "connected":
		_state = "connecting"
	return _generation


## 开始新的运行世代，并原子地失效旧 transport/pending。
## 返回值会同时被 editor 与 probe 写入 hello/request metadata。
func begin_generation() -> String:
	var pending_snapshot := _drain_pending()
	_clear_transports()
	cleanup_runtime_root()
	_generation = "%d-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec(), randi()]
	_state = "stopped"
	_write_generation_marker()
	_notify_pending_failures(pending_snapshot, "runtime generation replaced")
	return _generation


## 把 broker 标记为 connected（probe hello 已到达）
##
## 由 runtime debugger plugin 在收到 hello 事件时调用；
## 仅在状态机处于 connecting 时才推进到 connected。
func mark_connected() -> void:
	if not _last_attach_accepted:
		return
	if _state == "connecting":
		_state = "connected"
	_engine_connected = true
	_select_transport_sender()


## attach file transport(由 editor 侧文件 transport manager 调用)
##
## 保存 file transport 的 send callable，并按 EngineDebugger > file > none
## 的优先级选择实际发送端。已连接的 EngineDebugger 绝不会被 file hello 替换。
##
## @param probe_id probe 标识(全局唯一 hex)
## @param send file transport 注入的发送 callable
func attach_file_transport(probe_id: String, send: Callable, generation: String = "") -> bool:
	if not _accept_generation(generation):
		return false
	_file_probe_id = probe_id
	_file_sender = send
	_file_generation = generation
	_file_connected = true
	if not _engine_connected and _state == "stopped":
		_state = "connecting"
	if not _engine_connected:
		_session_id = probe_id.to_int() if probe_id.is_valid_int() else -1
	if not _engine_connected and _state == "connecting":
		_state = "connected"
	_select_transport_sender()
	if _session_started_at <= 0.0:
		_session_started_at = Time.get_unix_time_from_system()
	return true


## detach file transport(editor 侧主动关闭时调用)
##
## 仅在当前活跃 transport 是 file 时清空 file 状态。
##
## @param reason 人类可读的关闭原因
func detach_file_transport(
	reason: String = "file transport detached", generation: String = ""
) -> void:
	if not generation.is_empty() and generation != _file_generation:
		return
	var was_file_active: bool = _active_transport == "file"
	_file_probe_id = ""
	_file_sender = Callable()
	_file_connected = false
	_file_generation = ""
	_select_transport_sender()
	if was_file_active:
		detach(reason)


## 显式断开 EngineDebugger transport。
##
## 保留仍然有效的 file sender 作为 fallback；只有两个 transport 都不可用时
## 才一次性失败 pending。
func detach_engine_debugger(
	reason: String = "engine debugger detached", generation: String = ""
) -> void:
	if not generation.is_empty() and generation != _engine_generation:
		return
	if not _engine_connected and _engine_sender.is_null():
		return
	_engine_sender = Callable()
	_engine_connected = false
	_engine_generation = ""
	_select_transport_sender()
	if _file_connected and not _file_sender.is_null():
		_session_id = _file_probe_id.to_int() if _file_probe_id.is_valid_int() else -1
		_state = "connected"
		return
	_session_id = -1
	_state = "stopped"
	_fail_pending(reason)


## 由 transport 路径调用,显式切换活跃 transport 标识
##
## EngineDebugger hello 到达时切到 "engine_debugger",让上层能区分
## 当前生效的 transport。仅更新标识,不触碰 _sender。
##
## @param name transport 标识("engine_debugger" / "file" / "none")
func _set_active_transport(_name: String) -> void:
	# Compatibility hook; priority remains owned by the central selector.
	_select_transport_sender()


## 记录 transport 连通性；generation 由后续 transport 协商使用，保留在
## broker 边界以免 transport 自行持有会话状态。
func set_transport_connected(name: String, connected: bool, generation: String = "") -> void:
	if name == "file":
		_file_connected = connected
		if not connected:
			detach_file_transport("file transport disconnected", generation)
		else:
			_select_transport_sender()
		return
	if name == "engine_debugger":
		if not connected:
			detach_engine_debugger("engine debugger disconnected", generation)
		else:
			_engine_connected = true
			_select_transport_sender()


## 在 EngineDebugger、file、none 之间选择实际 sender。此方法是唯一的
## transport 优先级决策点，优先顺序固定为 EngineDebugger > file > none。
func _select_transport_sender() -> void:
	if _engine_connected and not _engine_sender.is_null():
		_sender = _engine_sender
		_active_transport = "engine_debugger"
		return
	if _file_connected and not _file_sender.is_null():
		_sender = _file_sender
		_active_transport = "file"
		return
	_sender = Callable()
	_active_transport = "none"


func _accept_generation(incoming: String) -> bool:
	if incoming.is_empty():
		return _generation.is_empty()
	if _generation.is_empty():
		_generation = incoming
		_write_generation_marker()
	return incoming == _generation


func _clear_transports() -> void:
	_session_id = -1
	_sender = Callable()
	_engine_sender = Callable()
	_engine_connected = false
	_engine_generation = ""
	_file_sender = Callable()
	_file_connected = false
	_file_generation = ""
	_file_probe_id = ""
	_active_transport = "none"
	_state = "stopped"
	_last_attach_accepted = true


## 清理仅由 gdapi runtime 使用的 root；不会接受任意调用方路径。
func cleanup_runtime_root() -> void:
	var root := ProjectSettings.globalize_path("res://.godot/gdapi_runtime").simplify_path()
	if not root.ends_with(".godot/gdapi_runtime"):
		return
	_remove_runtime_tree(root, root)


func _remove_runtime_tree(path: String, root: String) -> void:
	if path != root and not path.begins_with(root + "/") and not path.begins_with(root + "\\"):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		for file_name in dir.get_files():
			var file_path := path.path_join(file_name)
			if file_path.begins_with(root + "/") or file_path.begins_with(root + "\\"):
				DirAccess.remove_absolute(file_path)
		for dir_name in dir.get_directories():
			_remove_runtime_tree(path.path_join(dir_name), root)
	DirAccess.remove_absolute(path)


func _write_generation_marker() -> void:
	var root := ProjectSettings.globalize_path("res://.godot/gdapi_runtime").simplify_path()
	if not root.ends_with(".godot/gdapi_runtime") or _generation.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join("generation.json"), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"generation": _generation}))
	f.close()


## 主动断开当前会话,清理所有 pending
##
## @param reason 人类可读的断开原因,会被写入失败 reply
func detach(reason: String = "runtime detached") -> void:
	if _state == "stopped" and _pending.is_empty():
		return
	var pending_snapshot := _drain_pending()
	_clear_transports()
	cleanup_runtime_root()
	_notify_pending_failures(pending_snapshot, reason)


func _fail_pending(reason: String) -> void:
	var snapshot := _drain_pending()
	_notify_pending_failures(snapshot, reason)


## Snapshot and erase every pending request without invoking user code.
## Session teardown must finish before callbacks can re-enter request().
func _drain_pending() -> Array:
	var snapshot: Array = []
	for id in _pending.keys():
		snapshot.append([id, _pending[id].callback])
	_pending.clear()
	return snapshot


func _notify_pending_failures(snapshot: Array, reason: String) -> void:
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
			(
				on_complete
				. call(
					{
						"ok": false,
						"code": "conflict",
						"error": "runtime is not connected",
						"request_id": id,
					}
				)
			)
		return id
	var safe_payload: Dictionary = payload
	var message: Dictionary = Protocol.request(id, op, safe_payload, _generation)
	var verdict: Dictionary = Protocol.validate_message(message)
	if not bool(verdict.get("ok", false)):
		if on_complete.is_valid():
			(
				on_complete
				. call(
					{
						"ok": false,
						"code": verdict.get("code", "invalid_param"),
						"error": verdict.get("error", "invalid runtime message"),
						"request_id": id,
					}
				)
			)
		return id
	var bounded_timeout := clampi(
		timeout_ms if timeout_ms > 0 else DEFAULT_REQUEST_TIMEOUT_MS, 1, MAX_REQUEST_TIMEOUT_MS
	)
	var deadline_msec: int = Time.get_ticks_msec() + bounded_timeout
	_pending[id] = {
		"deadline_msec": deadline_msec,
		"callback": on_complete,
		"op": op,
		"generation": _generation,
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
	var verdict: Dictionary = Protocol.validate_message(message)
	if not bool(verdict.get("ok", false)):
		if Protocol.message_exceeds_limit(message):
			_complete_oversized_reply(message, verdict)
		return
	var dict: Dictionary = message
	var message_generation := String(dict.get("generation", ""))
	if not _generation.is_empty() and message_generation != _generation:
		return
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
	if String(entry.get("generation", "")) != message_generation:
		return
	entry = _take_pending(id)
	var cb: Callable = entry.callback
	if cb.is_valid():
		cb.call(dict)


## A size-invalid reply still contains enough bounded envelope metadata to
## correlate it with one live request. Complete that request immediately so a
## transport boundary cannot turn an explicit bound violation into a timeout.
func _complete_oversized_reply(message: Variant, verdict: Dictionary) -> void:
	if typeof(message) != TYPE_DICTIONARY:
		return
	var dict: Dictionary = message
	if int(dict.get("version", -1)) != Protocol.VERSION:
		return
	if String(dict.get("kind", "")) != "reply":
		return
	var raw_id: Variant = dict.get("id", null)
	if typeof(raw_id) != TYPE_INT or int(raw_id) < 1:
		return
	var message_generation := String(dict.get("generation", ""))
	if not _generation.is_empty() and message_generation != _generation:
		return
	var id := int(raw_id)
	if not _pending.has(id):
		return
	var pending_generation := String(Dictionary(_pending[id]).get("generation", ""))
	if pending_generation != message_generation:
		return
	_complete_with_failure(
		id,
		String(verdict.get("code", "invalid_param")),
		String(verdict.get("error", "runtime reply exceeds protocol bounds"))
	)


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
	var entry := _take_pending(id)
	if entry.is_empty():
		return
	var cb: Callable = entry.callback
	if cb.is_valid():
		(
			cb
			. call(
				{
					"ok": false,
					"code": code,
					"error": error,
					"request_id": id,
				}
			)
		)


## Remove ownership before invoking user code. Late replies, timeout ticks and
## disconnect cleanup all observe the id as completed, even during re-entrancy.
func _take_pending(id: int) -> Dictionary:
	if not _pending.has(id):
		return {}
	var entry: Dictionary = _pending[id]
	_pending.erase(id)
	return entry


## attach 前先把旧 pending 清理干净,避免重复 callback
func _prepare_new_session(reason: String) -> void:
	if _state == "stopped" and _pending.is_empty():
		return
	var pending_snapshot := _drain_pending()
	_clear_transports()
	_notify_pending_failures(pending_snapshot, reason)


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
