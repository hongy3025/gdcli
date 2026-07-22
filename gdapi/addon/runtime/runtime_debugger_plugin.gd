## 运行时 debugger plugin transport
##
## 作为 EditorPlugin 注入，把 EngineDebugger capture "gdapi" 当作
## broker ↔ runtime_probe 双向通道。本类不持有业务状态——broker 是
## 真正的 pending 字典与状态机所有者。
##
## 工作流程：
## 1. _setup_session(session_id) —— 拿到 EditorDebuggerSession 引用，缓存可用 session id；
## 2. _capture(message, data, session_id) —— 收到 runtime probe 推过来的 hello / reply，
##    hello 触发 broker attach + mark_connected，reply 走 broker.receive；
## 3. _clear(session_id) —— broker.detach("session cleared") + 移除本地缓存。

@tool
extends EditorDebuggerPlugin

## 由 setup() 注入的 broker 实例
var _broker: RefCounted = null

## session_id -> true (已建立 session 的占位,真正取引用走 _lookup_session)
var _sessions: Dictionary = {}

## 配置 broker
##
## @param broker 已经 setup 完毕的 GdApiRuntimeBroker 实例
func setup(broker: RefCounted) -> void:
	_broker = broker

## 是否希望接收 capture "gdapi"
##
## 必须返回 true,否则 _capture 不会被调用。
## @param name 通道名
func _has_capture(name: String) -> bool:
	return name == "gdapi"

## EditorDebuggerSession 启动时由编辑器调用
##
## 仅记录 session_id;真正的 broker attach 推迟到第一次 capture hello 到达,
## 避免 plugin 注册时(或编辑器调试面板空闲会话)把 broker 推到 connecting,
## 也避免 hello 之前的请求试图发送到不存在的 session。
##
## @param session_id 编辑器为新调试会话分配的 id
func _setup_session(session_id: int) -> void:
	_sessions[session_id] = true

## 接收 runtime probe 推过来的 reply / event / hello
##
## Godot 4.7 签名:`_capture(message: String, data: Array, session_id: int) -> bool`.
## - message 是 EngineDebugger.send_message 的 sub-channel(我们约定为 "gdapi")。
## - data 是 probe 推送的协议数组,data[0] 是 protocol v1 字典。
## - session_id 是 debugger session id。
##
## @param message 协议层子通道(我们只接受 "gdapi")
## @param data 数据数组,data[0] 是 protocol v1 字典
## @param session_id 对应 debugger session id
## @return true 表示已处理
func _capture(message: String, data: Array, session_id: int) -> bool:
	if message != "gdapi":
		return false
	if _broker == null:
		return true
	if data.is_empty():
		return true
	var payload: Variant = data[0]
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	# Hello 事件只用来推进状态机；reply 才走 broker.receive。
	if String(payload.get("event", "")) == "hello":
		_attach_to_session(session_id)
		_broker.mark_connected()
		return true
	_broker.receive(payload)
	return true

## EditorDebuggerSession 断开时回调
##
## @param session_id 已断开的 session
func _clear(session_id: int) -> void:
	if _sessions.has(session_id):
		_sessions.erase(session_id)
	if _broker != null:
		_broker.detach("session cleared")

## 把协议字典通过当前 session 推送给 runtime probe
##
## 返回 bool,告诉 broker 是否真的送达。session 引用每次发送时通过父类
## `get_session(id)` 现取,避免缓存悬空引用。
##
## @param session_id 目标 session
## @param message 协议 v1 字典
func _send_to_session(session_id: int, message: Dictionary) -> bool:
	if not _sessions.has(session_id):
		return false
	var session: RefCounted = _lookup_session(session_id)
	if session == null:
		return false
	var method_exists: bool = false
	for m in session.get_method_list():
		if String(m.name) == "send_message":
			method_exists = true
			break
	if not method_exists:
		return false
	session.send_message("gdapi", [message])
	return true

## 在编辑器中检索 EditorDebuggerSession。
##
## Godot 4.7 父类 `EditorDebuggerPlugin` 暴露 `get_session(id)`;
## 静态调用 `EditorInterface.get_debugger()` 在 4.7 不可用,改走父类方法。
##
## @param session_id 已知 session id
## @return session 引用或 null
func _lookup_session(session_id: int) -> RefCounted:
	if self.has_method("get_session"):
		var session: Variant = call("get_session", session_id)
		if session != null:
			return session
	return null

## 把当前 session 绑定到 broker(由 hello 路径触发)
##
## @param session_id 已知 session id
func _attach_to_session(session_id: int) -> void:
	if not _sessions.has(session_id):
		return
	var session: RefCounted = _lookup_session(session_id)
	if session == null:
		push_warning("[gdapi] hello arrived but session %d is unavailable" % session_id)
		return
	if _broker == null:
		return
	var send := func(message: Dictionary) -> bool:
		return _send_to_session(session_id, message)
	_broker.attach(session_id, send)