## GDAPI 插件入口模块
##
## 作为 Godot 编辑器插件的核心入口，负责初始化 HTTP 服务器、路由系统和日志管理。
## 主要功能：启动本地 HTTP 服务监听请求，扫描并注册路由处理器，管理插件生命周期。
## 通过元数据文件与外部工具通信，提供编辑器 API 的远程访问能力。

@tool
extends EditorPlugin

## 路由系统预加载引用
const Router := preload("res://addons/gdapi/runtime/router.gd")
const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")
const RuntimeDebuggerPlugin := preload("res://addons/gdapi/runtime/runtime_debugger_plugin.gd")
const RuntimeDebuggerRegistration := preload(
	"res://addons/gdapi/runtime/runtime_debugger_registration.gd"
)
const RuntimeProbe := preload("res://addons/gdapi/runtime/runtime_probe.gd")
const DeferredTaskRegistry := preload("res://addons/gdapi/runtime/deferred_task_registry.gd")
## 元数据文件路径，用于存储服务器连接信息
const META_PATH := "res://.godot/gdapi.json"
## 默认端口号，实际使用时会尝试从该端口开始绑定
const PORT_HINT: int = 7890
## 日志缓冲区最大条目数，防止内存无限增长
const MAX_LOG_ENTRIES: int = 1000

## 日志级别常量
const LOG_DEBUG := 0
const LOG_INFO := 1
const LOG_WARN := 2
const LOG_ERROR := 3
const MAX_AUDIT_ENTRIES: int = 1000

## 级别名称映射
const LOG_LEVEL_NAMES := {0: "debug", 1: "info", 2: "warn", 3: "error"}

## HTTP 服务器实例，处理网络请求
var _server: GdApiServer
## 路由系统实例，负责请求分发和处理
var _router: Router

## M3 运行时 broker 实例(RefCounted,生命周期跟随插件)
var _runtime_broker: RefCounted = null
## M3 runtime debugger plugin 实例(EditorDebuggerPlugin)
var _runtime_debugger_plugin: RefCounted = null
var _runtime_debugger_registration: RefCounted = null
## M3.1 runtime file transport (editor 侧 fallback transport manager)
var _runtime_file_transport: RefCounted = null
## Deferred high-risk route work.  It is ticked before accepting new requests.
var _deferred_task_registry: RefCounted = null
## 日志缓冲区，存储最近的日志条目用于远程查询

var _log_buffer: Array = []
## 日志序列号，用于增量获取日志
var _log_seq: int = 0
## 当前全局日志级别，默认 INFO
var _log_level: int = LOG_INFO

var _audit_buffer: Array = []
var _audit_seq: int = 0


## 插件初始化入口
##
## 当插件被加载到编辑器时调用。执行以下初始化流程：
## 1. 注册插件实例到引擎元数据，供路由处理器访问
## 2. 创建并启动 HTTP 服务器，尝试绑定到可用端口
## 3. 初始化路由系统并扫描注册所有路由处理器
## 4. 写入元数据文件供外部工具发现服务
## 5. 启用进程回调以处理请求轮询
## 6. 连接文件系统变化信号，实现路由热重载
## 7. M3：创建 runtime broker 和 EditorDebuggerPlugin,注册为 autoload
func _enter_tree() -> void:
	# 注册自身到 Engine meta，供路由访问
	Engine.set_meta("gdapi_plugin", self)
	_deferred_task_registry = DeferredTaskRegistry.new()

	_server = GdApiServer.create()
	var token := _generate_token()
	var port: int = _server.start(PORT_HINT, token)
	if port < 0:
		push_error("[gdapi] failed to bind any port in 7890..7953")
		return
	_router = Router.new()
	_router.scan("res://addons/gdapi/routes")
	_write_meta(port, token)
	set_process(true)

	# 连接文件系统变化信号，实现路由热重载
	var fs = EditorInterface.get_resource_filesystem()
	fs.filesystem_changed.connect(_on_filesystem_changed)

	# M3：创建并注册 runtime broker 和 EditorDebuggerPlugin
	_runtime_broker = RuntimeBroker.new()
	# 建立 editor 生命周期的首个 generation；project/run 会在 begin_connect()
	# 时切换到下一代并再次清理 runtime root。
	_runtime_broker.begin_generation()
	Engine.set_meta("gdapi_runtime_broker", _runtime_broker)
	# 4.7: add_debugger_plugin 需要 EditorDebuggerPlugin 实例(不是 Script)。
	# 传入已实例化的对象才能让 _setup_session / _capture 被编辑器调度。
	_runtime_debugger_plugin = RuntimeDebuggerPlugin.new()
	_runtime_debugger_plugin.setup(_runtime_broker)
	_runtime_debugger_registration = RuntimeDebuggerRegistration.new()
	_runtime_debugger_registration.setup(
		_runtime_debugger_plugin,
		func(debugger) -> void: add_debugger_plugin(debugger),
		func(debugger) -> void: remove_debugger_plugin(debugger)
	)
	_runtime_debugger_registration.register()
	add_autoload_singleton("GdApiRuntimeProbe", "res://addons/gdapi/runtime/runtime_probe.gd")

	# M3.1: 启动文件 transport manager(headless 下作为 EngineDebugger 不可达的 fallback)
	# 顺序:broker 先建好并写入 Engine meta,file transport 启动后扫描 hello.json
	# 时会调 attach_file_transport,这样 broker._active_transport 切到 file。
	_runtime_file_transport = (
		preload("res://addons/gdapi/runtime/runtime_transport_file_editor.gd").new()
	)
	_runtime_file_transport.setup(_runtime_broker)
	_runtime_file_transport.start()

	print("[gdapi] listening on 127.0.0.1:%d (%d routes)" % [port, _router.count()])


## 文件系统变化回调
##
## 当 Godot 编辑器检测到文件系统变化时调用。
## 重新扫描路由目录，更新路由表，实现路由热重载。
func _on_filesystem_changed() -> void:
	if _router:
		_router.scan("res://addons/gdapi/routes")
		print("[gdapi] routes reloaded (%d routes)" % _router.count())


## 插件卸载清理
##
## 当插件从编辑器卸载时调用。执行以下清理操作：
## 1. 停止进程回调
## 2. 停止 HTTP 服务器
## 3. 删除元数据文件
## 4. 从引擎元数据中移除插件引用
## 5. M3: 关闭 runtime broker,移除 autoload,移除 debugger plugin
func _exit_tree() -> void:
	set_process(false)
	if _deferred_task_registry != null:
		_deferred_task_registry.cancel_all("plugin exiting")
		_deferred_task_registry = null
	if _server and _server.is_running():
		_server.stop()
	# M3.1: 停止文件 transport manager,把 pending 同步失败回 callback
	if _runtime_file_transport != null:
		_runtime_file_transport.stop_all("plugin exiting")
		_runtime_file_transport.cleanup_root()
	# M3：先暂停运行期 broker、所有 pending 会立即被失败 callback
	if _runtime_broker != null:
		_runtime_broker.detach("plugin exiting")
	# 关闭 debugger plugin(4.7: 同样传 instance)
	if _runtime_debugger_registration != null:
		_runtime_debugger_registration.unregister()
	remove_autoload_singleton("GdApiRuntimeProbe")
	Engine.remove_meta("gdapi_runtime_broker")
	_runtime_broker = null
	_runtime_debugger_plugin = null
	_runtime_debugger_registration = null
	_runtime_file_transport = null
	_delete_meta()


## 每帧请求轮询处理
##
## 在编辑器空闲时轮询 HTTP 服务器，处理所有待处理的请求。
## 使用循环确保一次处理所有积压请求，避免请求延迟。
## M3: 同时推动 runtime broker 的 tick(),让超时请求被及时清除。
##
## @param _dt 帧时间间隔（未使用）
func _process(_dt: float) -> void:
	if _server == null or not _server.is_running():
		return
	if _deferred_task_registry != null:
		_deferred_task_registry.tick(Time.get_ticks_msec())
	if _runtime_broker != null:
		_runtime_broker.tick(Time.get_ticks_msec())
	# M3.1: 文件 transport manager 扫描 hello/outbox、处理 timeout
	if _runtime_file_transport != null:
		_runtime_file_transport.tick(Time.get_ticks_msec())
	while true:
		var req: Variant = _server.poll_request()
		if req == null:
			break
		_router.dispatch(req, _server)


func request_play_scene(scene_path: String) -> void:
	if not scene_path.is_empty():
		EditorInterface.play_custom_scene(scene_path)


func register_deferred_task(task: Dictionary) -> bool:
	return _deferred_task_registry != null and _deferred_task_registry.register(task)


## 添加日志条目到缓冲区
##
## 记录日志消息到内存缓冲区，支持远程查询和监控。
## 自动维护缓冲区大小，超出限制时移除最旧的条目。
## @param text 日志文本内容
## @param level 日志级别（info, warning, error 等）
func log_message(text: String, level: String = "info") -> void:
	_log_seq += 1
	(
		_log_buffer
		. append(
			{
				"seq": _log_seq,
				"level": level,
				"text": text,
				"ts": Time.get_unix_time_from_system(),
			}
		)
	)
	if _log_buffer.size() > MAX_LOG_ENTRIES:
		_log_buffer.pop_front()


## 获取指定序列号之后的日志条目
##
## 用于增量获取日志，客户端可以记住上次获取的序列号，
## 下次从该序列号之后开始获取新日志。
## @param since 起始序列号（不包含）
## @param limit 最大返回条目数
## @return 符合条件的日志条目数组
func get_log_since(since: int, limit: int) -> Array:
	var entries: Array = []
	for entry in _log_buffer:
		if entry.seq > since:
			entries.append(entry)
			if entries.size() >= limit:
				break
	return entries


func audit_event(event: Dictionary) -> void:
	_audit_seq += 1
	var entry := event.duplicate(true)
	entry["seq"] = _audit_seq
	entry["ts"] = Time.get_unix_time_from_system()
	_audit_buffer.append(entry)
	if _audit_buffer.size() > MAX_AUDIT_ENTRIES:
		var remove_index := 0
		for index in _audit_buffer.size():
			if String(_audit_buffer[index].get("safety", "")) not in ["dangerous", "file"]:
				remove_index = index
				break
		_audit_buffer.remove_at(remove_index)


func get_audit_since(since: int, limit: int, safety: String = "") -> Array:
	var entries: Array = []
	for entry in _audit_buffer:
		if entry.seq > since and (safety.is_empty() or entry.get("safety", "") == safety):
			entries.append(entry)
			if entries.size() >= limit:
				break
	return entries


func clear_audit() -> void:
	_audit_buffer.clear()


## 从 plugin.cfg 读取版本号
##
## 解析插件配置文件中的 version 字段，避免在 GDScript 中硬编码版本号。
## @return 版本号字符串，读取失败时返回 "unknown"
func _read_version_from_plugin_cfg() -> String:
	var cfg_path := "res://addons/gdapi/plugin.cfg"
	var f := FileAccess.open(cfg_path, FileAccess.READ)
	if f == null:
		return "unknown"
	var content := f.get_as_text()
	f.close()
	for line in content.split("\n"):
		if line.begins_with("version="):
			return line.substr(8).strip_edges().trim_prefix('"').trim_suffix('"')
	return "unknown"


## 检测当前 Godot 实例的 LSP 端口
##
## 从 EditorSettings 读取当前实例配置的 LSP 端口。
## 每个 Godot 实例有自己的 EditorSettings，因此可以获取该实例的 LSP 端口。
## @return LSP 端口号，读取失败时返回默认值 6005
func _detect_lsp_port() -> int:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting("network/language_server/remote_port"):
		return int(es.get_setting("network/language_server/remote_port"))
	return 6005


## 写入元数据文件
##
## 将服务器连接信息写入 JSON 文件，供外部工具（如 CLI）发现和连接服务。
## 包含 HTTP 端口、LSP 端口、进程 ID、启动时间和 API 版本。
## @param port 实际绑定的 HTTP 端口号
## @param token 认证 token
func _write_meta(port: int, token: String) -> void:
	var lsp_port := _detect_lsp_port()
	var version := _read_version_from_plugin_cfg()
	var meta := {
		"http_port": port,
		"lsp_port": lsp_port,
		"pid": OS.get_process_id(),
		"started_at": Time.get_datetime_string_from_system(true),
		"gdapi_version": version,
		"token": token,
	}
	var f := FileAccess.open(META_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[gdapi] cannot write " + META_PATH)
		return
	f.store_string(JSON.stringify(meta, "  "))
	f.close()


## 生成随机认证 token
##
## 生成 32 字符的十六进制随机字符串，用于 HTTP 请求认证。
## @return 随机 token 字符串
func _generate_token() -> String:
	var token := ""
	for i in range(32):
		token += "%x" % (randi() % 16)
	return token


## 删除元数据文件
##
## 在插件卸载时清理元数据文件，防止外部工具尝试连接已停止的服务。
func _delete_meta() -> void:
	if FileAccess.file_exists(META_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(META_PATH))
