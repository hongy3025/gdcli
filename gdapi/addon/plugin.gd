## GDAPI 插件入口模块
##
## 作为 Godot 编辑器插件的核心入口，负责初始化 HTTP 服务器、路由系统和日志管理。
## 主要功能：启动本地 HTTP 服务监听请求，扫描并注册路由处理器，管理插件生命周期。
## 通过元数据文件与外部工具通信，提供编辑器 API 的远程访问能力。

@tool
extends EditorPlugin

## 路由系统预加载引用
const Router := preload("res://addons/gdapi/runtime/router.gd")
## 元数据文件路径，用于存储服务器连接信息
const META_PATH := "res://.godot/gdapi.json"
## 默认端口号，实际使用时会尝试从该端口开始绑定
const PORT_HINT: int = 7890
## 日志缓冲区最大条目数，防止内存无限增长
const MAX_LOG_ENTRIES: int = 1000

## 日志级别常量
const LOG_DEBUG := 0
const LOG_INFO  := 1
const LOG_WARN  := 2
const LOG_ERROR := 3

## 级别名称映射
const LOG_LEVEL_NAMES := {0: "debug", 1: "info", 2: "warn", 3: "error"}

## HTTP 服务器实例，处理网络请求
var _server: GdApiServer
## 路由系统实例，负责请求分发和处理
var _router: Router

## 日志缓冲区，存储最近的日志条目用于远程查询
var _log_buffer: Array = []
## 日志序列号，用于增量获取日志
var _log_seq: int = 0
## 当前全局日志级别，默认 INFO
var _log_level: int = LOG_INFO

## 插件初始化入口
##
## 当插件被加载到编辑器时调用。执行以下初始化流程：
## 1. 注册插件实例到引擎元数据，供路由处理器访问
## 2. 创建并启动 HTTP 服务器，尝试绑定到可用端口
## 3. 初始化路由系统并扫描注册所有路由处理器
## 4. 写入元数据文件供外部工具发现服务
## 5. 启用进程回调以处理请求轮询
func _enter_tree() -> void:
	# 注册自身到 Engine meta，供路由访问
	Engine.set_meta("gdapi_plugin", self)

	_server = GdApiServer.create()
	var port: int = _server.start(PORT_HINT)
	if port < 0:
		push_error("[gdapi] failed to bind any port in 7890..7953")
		return
	_router = Router.new()
	_router.scan("res://addons/gdapi/routes")
	_write_meta(port)
	set_process(true)
	print("[gdapi] listening on 127.0.0.1:%d (%d routes)" % [port, _router.count()])

## 插件卸载清理
##
## 当插件从编辑器卸载时调用。执行以下清理操作：
## 1. 停止进程回调
## 2. 停止 HTTP 服务器
## 3. 删除元数据文件
## 4. 从引擎元数据中移除插件引用
func _exit_tree() -> void:
	set_process(false)
	if _server and _server.is_running():
		_server.stop()
	_delete_meta()
	Engine.remove_meta("gdapi_plugin")

## 每帧请求轮询处理
##
## 在编辑器空闲时轮询 HTTP 服务器，处理所有待处理的请求。
## 使用循环确保一次处理所有积压请求，避免请求延迟。
## @param _dt 帧时间间隔（未使用）
func _process(_dt: float) -> void:
    if _server == null or not _server.is_running():
        return
    while true:
        var req: Variant = _server.poll_request()
        if req == null:
            break
        _router.dispatch(req, _server)

## 添加日志条目到缓冲区
##
## 记录日志消息到内存缓冲区，支持远程查询和监控。
## 自动维护缓冲区大小，超出限制时移除最旧的条目。
## @param text 日志文本内容
## @param level 日志级别（info, warning, error 等）
func log_message(text: String, level: String = "info") -> void:
	_log_seq += 1
	_log_buffer.append({
		"seq": _log_seq,
		"level": level,
		"text": text,
		"ts": Time.get_unix_time_from_system(),
	})
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

## 写入元数据文件
##
## 将服务器连接信息写入 JSON 文件，供外部工具（如 CLI）发现和连接服务。
## 包含 HTTP 端口、LSP 端口、进程 ID、启动时间和 API 版本。
## @param port 实际绑定的 HTTP 端口号
func _write_meta(port: int) -> void:
    var lsp_port: int = 6005
    var es := EditorInterface.get_editor_settings()
    if es and es.has_setting("network/language_server/remote_port"):
        lsp_port = int(es.get_setting("network/language_server/remote_port"))
    var meta := {
        "http_port": port,
        "lsp_port": lsp_port,
        "pid": OS.get_process_id(),
        "started_at": Time.get_datetime_string_from_system(true),
        "gdapi_version": "0.2.0",
    }
    var f := FileAccess.open(META_PATH, FileAccess.WRITE)
    if f == null:
        push_error("[gdapi] cannot write " + META_PATH)
        return
    f.store_string(JSON.stringify(meta, "  "))
    f.close()

## 删除元数据文件
##
## 在插件卸载时清理元数据文件，防止外部工具尝试连接已停止的服务。
func _delete_meta() -> void:
    if FileAccess.file_exists(META_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(META_PATH))
