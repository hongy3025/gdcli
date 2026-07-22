## 运行时 debugger plugin transport
##
## 作为 EditorPlugin 注入，把 EngineDebugger capture "gdapi" 当作
## broker ↔ runtime_probe 双向通道。本类不持有业务状态——broker 是
## 真正的 pending 字典与状态机所有者。
##
## 工作流程：
## 1. _setup_session(session_id) —— 拿到 EditorDebuggerSession 引用，注册 send callable 给 broker；
## 2. _capture(name, message, data, session_id) —— 收到 runtime probe 推过来的 reply，向 broker.receive()；
## 3. _clear(session_id) —— broker.detach("session cleared") + 移除本地 session 引用。

@tool
extends EditorDebuggerPlugin

## 由 setup() 注入的 broker 实例
var _broker: RefCounted = null

## session_id -> EditorDebuggerSession 引用,用于 send_message
var _sessions: Dictionary = {}

## 配置 broker 与 manager
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
## - 注意从 `EditorInterface.get_debugger().get_session()` 拿到 session;
## - 把 send callable 注入 broker。
##
## @param session_id 编辑器为新调试会话分配的 id
func _setup_session(session_id: int) -> void:
	var session: RefCounted = _lookup_session(session_id)
	if session == null:
		push_warning("[gdapi] runtime debugger plugin failed to find session %d" % session_id)
		return
	_sessions[session_id] = session
	if _broker != null:
		var send := func(message: Dictionary) -> bool:
			return _send_to_session(session_id, message)
		_broker.attach(session_id, send)

## 接收 runtime probe 推过来的 reply / event / hello
##
## @param name 通道名（固定 "gdapi"）
## @param _message 协议层子通道（当前未使用）
## @param data data 数组,args[0] 是 protocol v1 字典
## @param session_id 对应 session id
func _capture(name: String, data: Array, session_id: int) -> bool:
	if name != "gdapi":
		return false
	if _broker == null:
		return true
	if data.is_empty():
		return true
	var payload: Variant = data[0]
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	_broker.receive(payload)
	# Hello 不走 broker.receive 而更新 connect 状态。
	if String(payload.get("event", "")) == "hello":
		_broker.begin_connect()
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
## 返回 bool,告诉 broker 是否真的送达。
##
## @param session_id 目标 session
## @param message 协议 v1 字典
func _send_to_session(session_id: int, message: Dictionary) -> bool:
	if not _sessions.has(session_id):
		return false
	var session: RefCounted = _sessions[session_id]
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
## 通过 EditorInterface.get_debugger().get_session(id);若返回值是 EditorDebuggerSession
## 或者任何支持 send_message 的对象即被保留。
##
## @param session_id 已知 session id
## @return session 引用或 null
func _lookup_session(session_id: int) -> RefCounted:
	# Godot 4.7 `EditorDebuggerPlugin` 内部保存 `_sessions: Dictionary`
	# (session_id -> EditorDebuggerSession)。子类通过 `get_session()` 访问。
	if self.has_method("get_session"):
		var session: Variant = call("get_session", session_id)
		if session != null:
			return session
	# 兑底: 直接访问父类可能暴露的 _sessions
	for prop in self.get_property_list():
		if String(prop.name) == "_sessions":
			var parent_sessions: Variant = self.get("_sessions")
			if typeof(parent_sessions) == TYPE_DICTIONARY and parent_sessions.has(session_id):
				return parent_sessions[session_id]
	return null

