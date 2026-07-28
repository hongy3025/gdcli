## 文件 transport —— 探针侧 (probe)
##
## 在游戏进程里通过共享文件系统与编辑器通信,绕开 Godot 4.7 headless
## 不支持的 EngineDebugger 远程调试通道。
##
## 目录布局（probe_id = 8 字符 hex）：
##   res://.godot/gdapi_runtime/<probe_id>/
##     hello.json       —— _ready 后立即写(或按 hello_delay_ms 推迟)
##     inbox/<id>.json  —— 编辑器写入的 request
##     outbox/<id>.json —— probe 处理后的 reply

@tool
class_name GdApiRuntimeTransportFileProbe
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

const DEFAULT_HANDLER_TIMEOUT_MS := 5_000
const MAX_HANDLER_TIMEOUT_MS := 25_000

## hello_delay_ms >0 时,start() 后推迟该毫秒数再写 hello.json
var hello_delay_ms: int = 0

## 自定义根目录(用于单元测试隔离);默认 res://.godot/gdapi_runtime
var root_dir_override: String = ""

## 唯一 probe_id,start() 时生成
var _probe_id: String = ""

## 是否已 start
var _started: bool = false

## request handler,由 editor 侧 bridge 调用;签名 (msg) -> reply
var _handler: Callable = Callable()

## 单个 handler 的超时；默认值与 runtime operation timeout 一致。
var handler_timeout_ms: int = DEFAULT_HANDLER_TIMEOUT_MS

## 已领取但尚未写出 reply 的 request id。值仅用于保活异步处理；
## id 是否存在才是唯一的状态契约。
var _inflight: Dictionary = {}

## 当前 probe 生命周期内已领取的 request id。完成后仍保留，避免重放 inbox
## 在 outbox 被编辑器消费后再次执行副作用。
var _claimed: Dictionary = {}

## hello 定时器到期时刻
var _hello_due_msec: int = 0
var _hello_sent: bool = false

func _init(p_hello_delay_ms: int = 0, p_root_override: String = "") -> void:
	hello_delay_ms = p_hello_delay_ms
	root_dir_override = p_root_override

## 暴露给测试 / 上层
func probe_id() -> String:
	if _probe_id.is_empty():
		_probe_id = _generate_probe_id()
	return _probe_id

## 返回根目录绝对路径
func root_path() -> String:
	if not root_dir_override.is_empty():
		return ProjectSettings.globalize_path(root_dir_override)
	return ProjectSettings.globalize_path("res://.godot/gdapi_runtime")

## 注册 request handler(msg) -> reply_dict
func set_request_handler(handler: Callable) -> void:
	_handler = handler

## 启动 transport:生成 probe_id,建子目录,写(或排程) hello.json
func start() -> void:
	if _started:
		return
	if _probe_id.is_empty():
		_probe_id = _generate_probe_id()
	var dir := root_path().path_join(_probe_id)
	DirAccess.make_dir_recursive_absolute(dir.path_join("inbox"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("outbox"))
	_started = true
	if hello_delay_ms <= 0:
		_write_hello_file()
	else:
		_hello_due_msec = Time.get_ticks_msec() + hello_delay_ms

## 停止并清理
func stop() -> void:
	if not _started:
		return
	_started = false
	_inflight.clear()
	_claimed.clear()
	var dir := root_path().path_join(_probe_id)
	DirAccess.remove_absolute(dir)

## 每帧调用:处理 hello 推迟、inbox 扫描
func tick(now_msec: int) -> void:
	if not _started:
		return
	if not _hello_sent and hello_delay_ms > 0 and now_msec >= _hello_due_msec:
		_write_hello_file()
	_expire_inflight(now_msec)
	_retry_pending_replies()
	_scan_inbox(now_msec)

## 私有:写 hello.json
func _write_hello_file() -> void:
	_hello_sent = true
	var hello := Protocol.event(0, "hello", {
		"protocol_version": Protocol.VERSION,
		"node": OS.get_processor_name(),
		"transport": "file",
	})
	var path := root_path().path_join(_probe_id).path_join("hello.json")
	_atomic_write(path, JSON.stringify(hello))

## 私有:扫描 inbox/ 处理每个 request
func _scan_inbox(_now_msec: int) -> void:
	var inbox := DirAccess.open(root_path().path_join(_probe_id).path_join("inbox"))
	if inbox == null:
		return
	for filename in inbox.get_files():
		if not filename.ends_with(".json"):
			continue
		var full_path := root_path().path_join(_probe_id).path_join("inbox").path_join(filename)
		var f := FileAccess.open(full_path, FileAccess.READ)
		if f == null:
			continue
		var raw := f.get_as_text()
		f.close()
		var dict: Dictionary = JSON.parse_string(raw) if not raw.is_empty() else {}
		if typeof(dict) != TYPE_DICTIONARY:
			inbox.remove(filename)
			continue
		# JSON.parse_string 会把所有数字恢复为 float,Protocol 要求 integer id。
		# 把 id / version 显式转型为 int 避免 validate_message 误判。
		if typeof(dict.get("version")) == TYPE_FLOAT:
			dict["version"] = int(dict.version)
		if typeof(dict.get("id")) == TYPE_FLOAT:
			dict["id"] = int(dict.id)
		var verdict := Protocol.validate_message(dict)
		if not bool(verdict.get("ok", false)):
			inbox.remove(filename)
			continue
		if String(dict.get("kind", "")) != "request":
			inbox.remove(filename)
			continue
		var id: int = int(dict.id)
		if not _claim_inbox(id):
			inbox.remove(filename)
			continue
		# 删除 inbox 防止重复消费；领取后异步处理只拥有内存中的 request。
		if inbox.remove(filename) != OK:
			_inflight.erase(id)
			_claimed.erase(id)
			continue
		_start_request(id, dict)

## 原子领取 request id；同一 id 的后续 inbox 文件只会被删除，不会再次分派。
func _claim_inbox(id: int) -> bool:
	if _claimed.has(id):
		return false
	_claimed[id] = true
	_inflight[id] = {"deadline_msec": Time.get_ticks_msec() + _handler_timeout()}
	return true

func _handler_timeout() -> int:
	return clampi(handler_timeout_ms, 1, MAX_HANDLER_TIMEOUT_MS)

## 将已经完成但首次落盘失败的 reply 重试；成功前保留 inflight 状态。
func _retry_pending_replies() -> void:
	for raw_id in _inflight.keys():
		var id: int = int(raw_id)
		var state: Dictionary = _inflight[id]
		if not state.has("reply"):
			continue
		if _write_reply(id, state.reply):
			_inflight.erase(id)

## 给仍在等待 handler 的 request 写入一次 timeout reply。
func _expire_inflight(now_msec: int) -> void:
	for raw_id in _inflight.keys():
		var id: int = int(raw_id)
		var state: Dictionary = _inflight[id]
		if state.has("reply") or now_msec < int(state.get("deadline_msec", now_msec + 1)):
			continue
		state["reply"] = _error_reply(id, "timeout", "runtime handler timed out")
		_inflight[id] = state

## 启动一个独立 request 协程。同步 handler 会在本调用内完成；
## suspended handler 会在其 await 的 signal/resume 后继续到 _finish_request。
func _start_request(id: int, message: Dictionary) -> void:
	var handler_reply: Variant = await _dispatch_request(message)
	if not _inflight.has(id) or Dictionary(_inflight[id]).has("reply"):
		return
	_finish_request(id, handler_reply)

## 规范化 handler 输出、验证 protocol v1 reply，并且无论成功或失败都释放 inflight。
func _finish_request(id: int, handler_reply: Variant) -> void:
	if not _inflight.has(id):
		return
	var reply: Dictionary = _make_reply(id, handler_reply)
	var state: Dictionary = _inflight[id]
	state["reply"] = reply
	_inflight[id] = state
	if _write_reply(id, reply):
		_inflight.erase(id)

func _write_reply(id: int, reply: Dictionary) -> bool:
	var out_path := root_path().path_join(_probe_id).path_join("outbox").path_join(str(id) + ".json")
	return _atomic_write(out_path, JSON.stringify(reply))

## 把 handler body 转为一个已验证且有界的 protocol reply。
func _make_reply(id: int, handler_reply: Variant) -> Dictionary:
	if typeof(handler_reply) != TYPE_DICTIONARY:
		return _error_reply(id, "invalid_param", "runtime handler returned an invalid reply")
	var reply_body: Dictionary = handler_reply
	if typeof(reply_body.get("ok", null)) != TYPE_BOOL:
		return _error_reply(id, "invalid_param", "runtime handler reply must contain boolean ok")
	var reply := Protocol.reply(id, bool(reply_body.ok), reply_body.get("result", null),
		String(reply_body.get("error", "")), String(reply_body.get("code", "")))
	var verdict: Dictionary = Protocol.validate_message(reply)
	if not bool(verdict.get("ok", false)):
		return _error_reply(id, String(verdict.get("code", "invalid_param")),
			"runtime handler reply is invalid: %s" % String(verdict.get("error", "invalid reply")))
	return reply

func _error_reply(id: int, code: String, error: String) -> Dictionary:
	return Protocol.reply(id, false, null, error, code)

## 私有:分派 request 到已注册 handler,或返回 not_supported
func _dispatch_request(req: Dictionary) -> Variant:
	if not _handler.is_valid():
		return {"ok": false, "code": "not_supported", "error": "no handler registered"}
	return await _handler.call(req)

## 私有:原子写（先写 .tmp 再 rename），返回写入和 rename 都成功的结果。
func _atomic_write(target_path: String, content: String) -> bool:
	var tmp_path := target_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(content)
	var write_error := f.get_error()
	f.close()
	if write_error != OK:
		DirAccess.remove_absolute(tmp_path)
		return false
	return DirAccess.rename_absolute(tmp_path, target_path) == OK

## 私有:生成 8 字符 hex probe id
func _generate_probe_id() -> String:
	var hex := "0123456789abcdef"
	var out := ""
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in 8:
		out += hex[rng.randi() % 16]
	return out
