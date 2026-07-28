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
## - tick() 由 plugin._process 每帧驱动,完成 hello 扫描和 outbox 收包。

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

## 是否已 start
var _started: bool = false

func _init(p_root_override: String = "") -> void:
	root_dir_override = p_root_override

## 注入 broker 引用
##
## broker 需暴露 attach_file_transport / detach_file_transport / receive；
## id、pending、deadline 和 callback 均由 broker.request() 持有。
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

## 只清理 editor file transport 自己的 root；root_dir_override 仅用于测试。
func cleanup_root() -> void:
	var root := root_path().simplify_path()
	var expected := ProjectSettings.globalize_path("res://.godot/gdapi_runtime").simplify_path()
	if not root_dir_override.is_empty():
		if root.is_empty():
			return
	else:
		if root != expected:
			return
	_remove_tree(root, root)

## 关闭所有 probe，并让 broker 统一完成尚未返回的请求。
##
## @param reason 人类可读的关闭原因
func stop_all(reason: String = "editor transport stopping") -> void:
	_started = false
	if _broker != null and _broker.has_method("detach_file_transport"):
		_broker.call("detach_file_transport", reason)
	_probes.clear()
	cleanup_root()

## 返回当前活跃的 probe_id 列表
func active_probe_ids() -> Array:
	return _probes.keys()

## 每帧调用:扫 hello、扫 outbox
func tick(now_msec: int) -> void:
	if not _started:
		return
	_scan_hello_files()
	_scan_outbox()

## 私有:扫描根目录下所有子目录,凡是含 hello.json 的都注册为 probe
func _scan_hello_files() -> void:
	var dir := DirAccess.open(root_path())
	if dir == null:
		return
	for name in dir.get_directories():
		var hello_path := root_path().path_join(name).path_join("hello.json")
		if _probes.has(name):
			if not FileAccess.file_exists(hello_path):
				_detach_probe(name, "probe hello disappeared")
				continue
			var current_hello := _read_json(hello_path)
			if not _hello_matches_probe(name, current_hello):
				_detach_probe(name, "probe hello generation changed")
			continue
		if not FileAccess.file_exists(hello_path):
			continue
		var hello := _read_json(hello_path)
		if not _valid_hello(hello):
			_cleanup_probe_dir(name)
			continue
		_attach_probe(name, hello)

## 私有:为单个 probe 创建 send callable,注入 broker
##
## send callable 把字典写到该 probe 的 inbox/<id>.json。
## broker 调用 attach_file_transport 后,broker 的 _sender 会被切到本 callable,
## broker 内部 _active_transport 标为 "file"。
func _attach_probe(probe_id: String, hello: Dictionary) -> void:
	if _broker == null:
		_probes[probe_id] = {"attached": false}
		return
	var probe_root := root_path().path_join(probe_id)
	DirAccess.make_dir_recursive_absolute(probe_root.path_join("inbox"))
	DirAccess.make_dir_recursive_absolute(probe_root.path_join("outbox"))
	var self_ref := self
	var send := func(message: Dictionary) -> bool:
		var raw_id: Variant = message.get("id", 0)
		var id_int: int = int(raw_id)
		var inbox_path := root_path().path_join(probe_id).path_join("inbox").path_join(str(id_int) + ".json")
		return self_ref._atomic_write(inbox_path, JSON.stringify(message))
	var generation := _hello_generation(hello)
	var attached := true
	if _broker.has_method("attach_file_transport"):
		attached = bool(_broker.call("attach_file_transport", probe_id, send, generation))
	if not attached:
		_cleanup_probe_dir(probe_id)
		return
	_probes[probe_id] = {"attached": true, "generation": generation}

## 私有:扫描每个 probe 的 outbox，删除文件后将完整 reply 交给 broker。
func _scan_outbox() -> void:
	for raw_probe_id in _probes.keys():
		var probe_id: String = String(raw_probe_id)
		if not _probes.has(probe_id):
			continue
		if not FileAccess.file_exists(root_path().path_join(probe_id).path_join("hello.json")):
			_detach_probe(probe_id, "probe hello disappeared")
			continue
		var probe_state: Dictionary = _probes[probe_id]
		var out_dir := DirAccess.open(root_path().path_join(probe_id).path_join("outbox"))
		if out_dir == null:
			continue
		for filename in out_dir.get_files():
			if not filename.ends_with(".json"):
				continue
			var full := root_path().path_join(probe_id).path_join("outbox").path_join(filename)
			var f := FileAccess.open(full, FileAccess.READ)
			if f == null:
				continue
			var raw := f.get_as_text()
			f.close()
			# 先删除，确保重复文件或 callback 重入不能二次完成请求。
			out_dir.remove(filename)
			if raw.is_empty():
				continue
			var parser := JSON.new()
			if parser.parse(raw) != OK:
				continue
			var dict: Variant = parser.data
			if typeof(dict) != TYPE_DICTIONARY:
				continue
			var reply: Dictionary = dict
			_normalize_protocol_integers(reply)
			var verdict: Dictionary = Protocol.validate_message(reply)
			if not bool(verdict.get("ok", false)):
				continue
			if String(reply.get("kind", "")) != "reply":
				continue
			var reply_generation := String(reply.get("generation", ""))
			if String(probe_state.get("generation", "")) != reply_generation:
				continue
			if _broker != null and _broker.has_method("receive"):
				_broker.call("receive", reply)

func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parser := JSON.new()
	if parser.parse(f.get_as_text()) != OK:
		f.close()
		return {}
	var raw: Variant = parser.data
	f.close()
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var result: Dictionary = raw
	_normalize_protocol_integers(result)
	return result

func _hello_generation(hello: Dictionary) -> String:
	var result: Variant = hello.get("result", {})
	return String(result.get("generation", "")) if typeof(result) == TYPE_DICTIONARY else ""

func _valid_hello(hello: Dictionary) -> bool:
	if hello.is_empty() or int(hello.get("version", -1)) != Protocol.VERSION:
		return false
	if typeof(hello.get("id")) != TYPE_INT or int(hello.get("id")) != 0:
		return false
	if String(hello.get("kind", "")) != "event" or String(hello.get("event", "")) != "hello":
		return false
	var result: Variant = hello.get("result", null)
	if typeof(result) != TYPE_DICTIONARY or int(result.get("protocol_version", -1)) != Protocol.VERSION:
		return false
	var raw_generation: Variant = result.get("generation", null)
	if typeof(raw_generation) != TYPE_STRING or String(raw_generation).is_empty():
		return false
	var raw_pid: Variant = result.get("pid", null)
	if typeof(raw_pid) != TYPE_INT or int(raw_pid) <= 0:
		return false
	var raw_started_at: Variant = result.get("started_at", null)
	if typeof(raw_started_at) != TYPE_INT and typeof(raw_started_at) != TYPE_FLOAT:
		return false
	if float(raw_started_at) <= 0.0:
		return false
	var transport := String(result.get("transport", ""))
	if transport != "file" and transport != "engine_debugger":
		return false
	var broker_generation := ""
	if _broker != null and _broker.has_method("status"):
		broker_generation = String(_broker.call("status").get("generation", ""))
	var generation := _hello_generation(hello)
	# 本轮尚未有 broker generation 时，第一条结构合法 hello 负责绑定它；
	# 一旦绑定，后续 hello 必须精确匹配当前 generation。
	return broker_generation.is_empty() or generation == broker_generation

func _hello_matches_probe(probe_id: String, hello: Dictionary) -> bool:
	if not _valid_hello(hello):
		return false
	return String(_probes[probe_id].get("generation", "")) == _hello_generation(hello)

func _detach_probe(probe_id: String, reason: String) -> void:
	if not _probes.has(probe_id):
		return
	var generation := String(_probes[probe_id].get("generation", ""))
	_probes.erase(probe_id)
	if _broker != null and _broker.has_method("detach_file_transport"):
		_broker.call("detach_file_transport", reason, generation)
	_cleanup_probe_dir(probe_id)

func _cleanup_probe_dir(probe_id: String) -> void:
	var probe_dir := root_path().path_join(probe_id)
	_remove_tree(probe_dir, root_path())

func _remove_tree(path: String, root: String) -> void:
	if path != root and not path.begins_with(root + "/") and not path.begins_with(root + "\\"):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		for file_name in dir.get_files():
			var file_path := path.path_join(file_name)
			if file_path.begins_with(root + "/") or file_path.begins_with(root + "\\"):
				DirAccess.remove_absolute(file_path)
		for dir_name in dir.get_directories():
			_remove_tree(path.path_join(dir_name), root)
	DirAccess.remove_absolute(path)

func _normalize_protocol_integers(message: Dictionary) -> void:
	if typeof(message.get("version")) == TYPE_FLOAT:
		message["version"] = int(message.version)
	if typeof(message.get("id")) == TYPE_FLOAT:
		message["id"] = int(message.id)
	var result: Variant = message.get("result", null)
	if typeof(result) == TYPE_DICTIONARY and typeof(result.get("protocol_version")) == TYPE_FLOAT:
		result["protocol_version"] = int(result.protocol_version)
	if String(message.get("kind", "")) == "event" and String(message.get("event", "")) == "hello":
		if typeof(result) == TYPE_DICTIONARY and typeof(result.get("pid")) == TYPE_FLOAT:
			var pid_value: float = float(result.pid)
			if pid_value >= 1.0 and pid_value <= 2147483647.0 and pid_value == floor(pid_value):
				result["pid"] = int(pid_value)

## 私有:原子写(先写 .tmp 再 rename)
func _atomic_write(target_path: String, content: String) -> bool:
	var tmp_path := target_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(content)
	f.close()
	return DirAccess.rename_absolute(tmp_path, target_path) == OK
