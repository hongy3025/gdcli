## 运行时 debugger plugin transport
##
## 作为 EditorPlugin 注入，把 EngineDebugger capture "gdapi:protocol" 当作
## broker ↔ runtime_probe 双向通道。本类不持有业务状态——broker 是
## 真正的 pending 字典与状态机所有者。
##
## 工作流程：
## 1. _setup_session(session_id) —— 拿到 EditorDebuggerSession 引用，缓存可用 session id；
## 2. _capture(message, data, session_id) —— 收到 runtime probe 推过来的 hello / reply，
##    hello 触发 broker attach + mark_connected，reply 走 broker.receive；
## 3. _clear(session_id) —— 仅活动 session 触发 broker.detach("session cleared")。

@tool
extends EditorDebuggerPlugin

const DebuggerBridge := preload("res://addons/gdapi/runtime/runtime_debugger_bridge.gd")

## 由 setup() 注入的 broker 实例
var _broker: RefCounted = null
## 可在 headless Godot 中单测的 capture/setup/clear 行为桥接。
var _bridge: RefCounted = null


func _init() -> void:
	_bridge = DebuggerBridge.new()


## 配置 broker
##
## @param broker 已经 setup 完毕的 GdApiRuntimeBroker 实例
func setup(broker: RefCounted) -> void:
	_broker = broker
	var lookup := func(session_id: int) -> Variant: return _lookup_session(session_id)
	_bridge.setup(broker, lookup)


## 是否希望接收以 "gdapi:" 为前缀的 capture
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
	_bridge.setup_session(session_id)


## 接收 runtime probe 推过来的 reply / event / hello
##
## Godot 4.7 签名:`_capture(message: String, data: Array, session_id: int) -> bool`.
## - message 是 EngineDebugger.send_message 的完整 channel(我们约定为 "gdapi:protocol")。
## - data 是 probe 推送的协议数组,data[0] 是 protocol v1 字典。
## - session_id 是 debugger session id。
##
## @param message 完整协议 channel(我们只接受 "gdapi:protocol")
## @param data 数据数组,data[0] 是 protocol v1 字典
## @param session_id 对应 debugger session id
## @return true 表示已处理
func _capture(message: String, data: Array, session_id: int) -> bool:
	return _bridge.capture(message, data, session_id)


## EditorDebuggerSession 断开时回调
##
## @param session_id 已断开的 session
func _clear(session_id: int) -> void:
	_bridge.clear(session_id)


## 把协议字典通过当前 session 推送给 runtime probe
##
## 返回 bool,告诉 broker 是否真的送达。session 引用每次发送时通过父类
## `get_session(id)` 现取,避免缓存悬空引用。
##
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
