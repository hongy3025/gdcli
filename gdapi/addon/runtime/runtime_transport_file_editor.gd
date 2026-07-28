## 文件 transport —— 编辑器侧 (plugin)
##
## 每帧扫描 res://.godot/gdapi_runtime/*/hello.json 发现 probe;
## 通过 send callable 注入 GdApiRuntimeBroker,与 EngineDebugger transport
## 并存(优先 EngineDebugger;headless 下回落到 file)。
##
## 目录布局（probe_id 由 probe 侧生成并写入 hello.json）：
##   res://.godot/gdapi_runtime/<probe_id>/
##     hello.json       —— probe 侧写,供 editor 扫描
##     inbox/<id>.json  —— editor 写入的 request
##     outbox/<id>.json —— probe 写回的 reply
##
## 设计要点：
## - 单 probe 设计:取当前活跃 probe 的 keys()[0] 作为目标;不支持多 probe 并存;
## - 文件 transport 路径与 EngineDebugger transport 在 broker 内并存(由 broker
##   内部的 _active_transport 决定哪一个 sender 真正发送),本类只负责把 send callable
##   通过 attach_file_transport 注入 broker;
## - tick() 由 plugin._process 每帧驱动,完成 hello 扫描、outbox 收包、timeout 清理。

@tool
class_name GdApiRuntimeTransportFileEditor
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

## 自定义根目录(用于单元测试隔离);默认 res://.godot/gdapi_runtime
var root_dir_override: String = ""

## 注入的 broker 引用(由 plugin 提供)
var _broker: RefCounted = null

## probe_id -> {attached: bool, send: Callable}
## 当前活跃 probe 表;当 EngineDebugger transport 抢到控制权时,本表依然保留
## (用于接收残余 outbox),但 broker 的 sender 走 EngineDebugger 路径。
var _probes: Dictionary = {}

## id -> {probe_id, deadline_msec, callback, op}
var _pending: Dictionary = {}

## 下一个请求 id;单调递增
var _next_id: int = 0

## 是否已 start
var _started: bool = false

func _init(p_root_override: String = "") -> void:
	root_dir_override = p_root_override

## 注入 broker 引用
##
## broker 需暴露 allocate_id / attach_file_transport / detach_file_transport;
## 实际请求调度由 broker.request() 自身持有 sender。
func setup(broker: RefCounted) -> void:
	_broker = broker

## 返回根目录绝对路径
func root_path() -> String:
	if not root_dir_override.is_empty():
		return ProjectSettings.globalize_path(root_dir_override)
	return ProjectSettings.globalize_path("res://.godot/gdapi_runtime")

## 启动 manager:确保根目录存在
func start() -> void:
	_started = true
	DirAccess.make_dir_recursive_absolute(root_path())

## 关闭所有 probe,清空 pending 并以 conflict 通知所有 callback
##
## @param reason 人类可读的关闭原因
func stop_all(reason: String = "editor transport stopping") -> void:
	_started = false
	var ids: Array = _pending.keys()
	for id in ids:
		var entry: Dictionary = _pending[id]
		var cb: Callable = entry.callback
		if cb.is_valid():
			cb.call({
				"ok": false,
				"code": "conflict",
				"error": reason,
				"request_id": int(id),
			})
	_pending.clear()
	_probes.clear()

## 返回当前活跃的 probe_id 列表
func active_probe_ids() -> Array:
	return _probes.keys()

## 当前 pending 数量
func pending_count() -> int:
	return _pending.size()

## 发送一个 request:
## 1) 把消息写到 inbox/<id>.json
## 2) 记录 pending,带 deadline 和 callback
## 3) 返回整数 id(失败立即回调时 id 也保留)
##
## @param op 协议 op 名
## @param payload 业务字段字典
## @param timeout_ms 超时毫秒,<=0 时默认 5000
## @param on_complete 收到 reply 或失败时调用的 callback
## @return 本次请求的 id;无 probe 时返回 -1 并立即 callback conflict
func request(op: String, payload: Dictionary, timeout_ms: int, on_complete: Callable) -> int:
	if _probes.is_empty():
		on_complete.call({
			"ok": false,
			"code": "conflict",
			"error": "no runtime probe connected",
			"request_id": -1,
		})
		return -1
	# 单 probe 设计:始终取第一个活跃 probe
	var probe_id: String = _probes.keys()[0]
	_next_id += 1
	var id := _next_id
	var msg := Protocol.request(id, op, payload)
	var bounded_timeout: int = timeout_ms if timeout_ms > 0 else 5000
	var deadline_msec: int = Time.get_ticks_msec() + bounded_timeout
	_pending[id] = {
		"probe_id": probe_id,
		"deadline_msec": deadline_msec,
		"callback": on_complete,
		"op": op,
	}
	var inbox_path := root_path().path_join(probe_id).path_join("inbox").path_join(str(id) + ".json")
	_atomic_write(inbox_path, JSON.stringify(msg))
	return id

## 每帧调用:扫 hello、扫 outbox、清理 timeout
func tick(now_msec: int) -> void:
	if not _started:
		return
	_scan_hello_files()
	_scan_outbox()
	_expire_timeouts(now_msec)

## 私有:扫描根目录下所有子目录,凡是含 hello.json 的都注册为 probe
func _scan_hello_files() -> void:
	var dir := DirAccess.open(root_path())
	if dir == null:
		return
	for name in dir.get_directories():
		var hello_path := root_path().path_join(name).path_join("hello.json")
		if not FileAccess.file_exists(hello_path):
			continue
		if _probes.has(name):
			continue
		_attach_probe(name)

## 私有:为单个 probe 创建 send callable,注入 broker
##
## send callable 把字典写到该 probe 的 inbox/<id>.json。
## broker 调用 attach_file_transport 后,broker 的 _sender 会被切到本 callable,
## broker 内部 _active_transport 标为 "file"。
func _attach_probe(probe_id: String) -> void:
	if _broker == null:
		_probes[probe_id] = {"attached": false}
		return
	var self_ref := self
	var send := func(message: Dictionary) -> bool:
		var raw_id: Variant = message.get("id", 0)
		var id_int: int = int(raw_id)
		var inbox_path := root_path().path_join(probe_id).path_join("inbox").path_join(str(id_int) + ".json")
		self_ref._atomic_write(inbox_path, JSON.stringify(message))
		return true
	if _broker.has_method("attach_file_transport"):
		_broker.call("attach_file_transport", probe_id, send)
	_probes[probe_id] = {"attached": true}

## 私有:扫描每个 probe 的 outbox,匹配 pending id 的文件被读取、删除并触发 callback
func _scan_outbox() -> void:
	for probe_id in _probes.keys():
		var out_dir := DirAccess.open(root_path().path_join(probe_id).path_join("outbox"))
		if out_dir == null:
			continue
		for filename in out_dir.get_files():
			if not filename.ends_with(".json"):
				continue
			var id_str := filename.get_basename()
			if not id_str.is_valid_int():
				out_dir.remove(filename)
				continue
			var id := int(id_str)
			if not _pending.has(id):
				# unknown id：清理掉,避免下次 tick 重复处理
				out_dir.remove(filename)
				continue
			var full := root_path().path_join(probe_id).path_join("outbox").path_join(filename)
			var f := FileAccess.open(full, FileAccess.READ)
			if f == null:
				continue
			var raw := f.get_as_text()
			f.close()
			# 删除文件,避免重复消费
			out_dir.remove(filename)
			if raw.is_empty():
				continue
			var dict: Variant = JSON.parse_string(raw)
			if typeof(dict) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = _pending[id]
			_pending.erase(id)
			var cb: Callable = entry.callback
			if cb.is_valid():
				cb.call(dict)

## 私有:把过期的 pending 一次性清理并以 timeout 通知 callback
func _expire_timeouts(now_msec: int) -> void:
	var expired: Array = []
	for id in _pending.keys():
		if int(_pending[id].deadline_msec) <= now_msec:
			expired.append(id)
	for id in expired:
		var entry: Dictionary = _pending[id]
		_pending.erase(id)
		var cb: Callable = entry.callback
		if cb.is_valid():
			cb.call({
				"ok": false,
				"code": "timeout",
				"error": "runtime request timed out",
				"request_id": int(id),
			})

## 私有:原子写(先写 .tmp 再 rename)
func _atomic_write(target_path: String, content: String) -> void:
	var tmp_path := target_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(content)
	f.close()
	DirAccess.rename_absolute(tmp_path, target_path)
