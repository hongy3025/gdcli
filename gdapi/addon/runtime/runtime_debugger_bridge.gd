## Testable EngineDebugger bridge shared by the native EditorDebuggerPlugin.
##
## This class owns the protocol-facing capture/setup/clear behavior. Keeping
## it free of the virtual EditorDebuggerPlugin base makes the behavior testable
## in headless Godot while preserving the native plugin boundary.

@tool
class_name GdApiRuntimeDebuggerBridge
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

var _broker: RefCounted = null
var _lookup_session: Callable = Callable()
var _sessions: Dictionary = {}
var _active_session_id: int = -1

func setup(broker: RefCounted, lookup: Callable = Callable()) -> void:
	_broker = broker
	_lookup_session = lookup

func setup_session(session_id: int) -> void:
	_sessions[session_id] = true

## Explicit seam for behavioral tests and narrow host integrations.
## The real plugin resolves sessions through its injected lookup callable.
func set_session_override(session_id: int, session: RefCounted) -> void:
	_sessions[session_id] = session

func capture(message: String, data: Array, session_id: int) -> bool:
	if message != "gdapi":
		return false
	if _broker == null:
		return true
	if data.is_empty():
		return true
	var payload: Variant = data[0]
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	var dict: Dictionary = payload
	if String(dict.get("event", "")) == "hello":
		if not _valid_hello(dict):
			return false
		if not _attach_to_session(session_id):
			return false
		_active_session_id = session_id
		_broker.mark_connected()
		if _broker.has_method("_set_active_transport"):
			_broker.call("_set_active_transport", "engine_debugger")
		return true
	_broker.receive(dict)
	return true

func clear(session_id: int) -> void:
	if _sessions.has(session_id):
		_sessions.erase(session_id)
	if session_id != _active_session_id:
		return
	_active_session_id = -1
	if _broker == null:
		return
	if _broker.has_method("detach_engine_debugger"):
		_broker.call("detach_engine_debugger", "session cleared")
	else:
		_broker.detach("session cleared")

func _valid_hello(payload: Dictionary) -> bool:
	# Protocol.event(0, "hello", ...) is the existing runtime hello shape;
	# normal request/reply validation still requires positive ids.
	if typeof(payload.get("version")) != TYPE_INT or int(payload.version) != Protocol.VERSION:
		return false
	if typeof(payload.get("id")) != TYPE_INT or int(payload.id) != 0:
		return false
	if String(payload.get("kind", "")) != "event":
		return false
	if String(payload.get("event", "")) != "hello":
		return false
	var result: Variant = payload.get("result", null)
	if typeof(result) != TYPE_DICTIONARY:
		return false
	if typeof(result.get("protocol_version")) != TYPE_INT:
		return false
	return int(result.get("protocol_version")) == Protocol.VERSION

func _attach_to_session(session_id: int) -> bool:
	if not _sessions.has(session_id):
		return false
	var session: RefCounted = _lookup_session_value(session_id)
	if session == null or _broker == null:
		return false
	var send := func(message: Dictionary) -> bool:
		return _send_to_session(session_id, message)
	_broker.attach(session_id, send)
	return true

func _lookup_session_value(session_id: int) -> RefCounted:
	var cached: Variant = _sessions.get(session_id, null)
	if cached is RefCounted:
		return cached
	if not _lookup_session.is_valid():
		return null
	var resolved: Variant = _lookup_session.call(session_id)
	if resolved is RefCounted:
		return resolved
	return null

func _send_to_session(session_id: int, message: Dictionary) -> bool:
	var session: RefCounted = _lookup_session_value(session_id)
	if session == null or not session.has_method("send_message"):
		return false
	session.call("send_message", "gdapi", [message])
	return true
