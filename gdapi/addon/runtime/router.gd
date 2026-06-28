## 命令系统核心模块
##
## 负责扫描、注册和分发 HTTP 请求到对应的命令处理器。
## 支持自动扫描目录下的 GDScript 文件作为命令处理器，提供内置命令（如 ping 和命令列表）。
## 使用路径匹配机制，将请求路径映射到处理器脚本。

@tool
extends RefCounted

## 请求类预加载引用
const GdApiRequest := preload("res://addons/gdapi/runtime/request.gd")
## 响应类预加载引用
const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")
## 内置 ping 命令处理器
const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
## 内置路由名列表处理器
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")
## 内置路由详情帮助处理器
const BuiltinHelp := preload("res://addons/gdapi/runtime/builtin_help.gd")
## 内置命令详细列表处理器
const BuiltinCommands := preload("res://addons/gdapi/runtime/builtin_commands.gd")
## 内置单个命令帮助处理器
const BuiltinCommandHelp := preload("res://addons/gdapi/runtime/builtin_command_help.gd")

## 命令注册表，键为路径（如 "editor/scene/save"），值为处理器脚本
var _routes: Dictionary = {}
## 内置路由名列表处理器实例
var _builtin_routes_handler: BuiltinRoutes
## 内置路由详情帮助处理器实例
var _builtin_help_handler: BuiltinHelp
## 内置命令详细列表处理器实例
var _builtin_commands_handler: BuiltinCommands
## 内置单个命令帮助处理器实例
var _builtin_command_help_handler: BuiltinCommandHelp
## 命令文件修改时间记录，键为文件路径，值为修改时间戳
var _file_mtimes: Dictionary = {}
## 是否需要更新内置命令处理器（命令列表变化时触发）
var _needs_update: bool = false

## 扫描并注册命令处理器
##
## 使用 mtime 检查文件变化，只有变化的文件才重新加载。
## 首次扫描或强制刷新时加载所有文件。
## @param root_dir 命令处理器根目录路径
## @param force 是否强制全量扫描（忽略 mtime 检查）
func scan(root_dir: String, force: bool = false) -> void:
	if force:
		_routes.clear()
		_file_mtimes.clear()
		_needs_update = true

	_routes["gdapi/health/ping"] = BuiltinPing

	# 统一扫描 routes/ 目录下的所有子目录
	_scan_dir_with_mtime(root_dir, "", force)

	if _needs_update:
		_refresh_builtin_handlers()

## 获取已注册命令总数
##
## 包含内置的 health/ping 命令。
## @return 命令数量
func count() -> int:
	# _routes 已含 health/ping；额外三个内置命令：gdapi/routes + gdapi/commands + gdapi/help
	return _routes.size() + 3

func _refresh_builtin_handlers() -> void:
	_builtin_routes_handler = BuiltinRoutes.new()
	_builtin_help_handler = BuiltinHelp.new()
	_builtin_commands_handler = BuiltinCommands.new()
	_builtin_command_help_handler = BuiltinCommandHelp.new()
	var names: Array = _routes.keys()
	names.append("gdapi/routes")
	names.append("gdapi/commands")
	names.append("gdapi/help")
	names.sort()
	_builtin_routes_handler.set_route_names(names)

	var all_routes: Dictionary = _routes.duplicate()
	all_routes["gdapi/routes"] = BuiltinRoutes
	all_routes["gdapi/commands"] = BuiltinCommands
	all_routes["gdapi/help"] = BuiltinCommandHelp
	_builtin_help_handler.set_routes(all_routes)
	_builtin_commands_handler.set_routes(all_routes)
	_builtin_command_help_handler.set_routes(all_routes)
	_needs_update = false

## 递归扫描目录注册命令（带 mtime 检查）
##
## 递归遍历目录，检查文件修改时间，只有变化的文件才重新加载。
## 文件名（去掉 .gd 后缀）作为命令名称，子目录名作为路径前缀。
## 以 _ 开头的文件会被忽略。
## @param dir_path 要扫描的目录路径
## @param prefix 路径前缀（用于构建完整命令路径）
## @param force 是否强制全量扫描
func _scan_dir_with_mtime(dir_path: String, prefix: String, force: bool) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			var sub_prefix := (prefix + "/" + name) if prefix != "" else name
			_scan_dir_with_mtime(full, sub_prefix, force)
		elif name.ends_with(".gd") and not name.begins_with("_"):
			var route_name := name.substr(0, name.length() - 3)
			var key := (prefix + "/" + route_name) if prefix != "" else route_name
			var mtime := FileAccess.get_modified_time(full)
			var old_mtime: int = _file_mtimes.get(full, 0)
			if force or mtime != old_mtime:
				var script: Script = load(full) as Script
				if script != null:
					_routes[key] = script
					_file_mtimes[full] = mtime
					_needs_update = true
		name = dir.get_next()
	dir.list_dir_end()

## 分发请求到对应的命令处理器
##
## 根据请求路径查找处理器并执行。支持以下特殊命令：
## - /routes：返回所有可用路由名称列表
## - /ping：内置健康检查命令
## - /help：路由详情帮助
## - /commands：命令详细列表
## - /command-help：单个命令帮助
## @param req_dict 原始请求数据字典
## @param server HTTP 服务器实例
func dispatch(req_dict: Dictionary, server) -> void:
	var id: int = req_dict["id"]
	var method: String = req_dict["method"]
	var path: String = req_dict["path"]

	# 只支持 POST 方法
	if method != "POST":
		_reply_error(server, id, 405, "only POST is supported", "method_not_allowed")
		return

	var key: String = path.trim_prefix("/")

	# 处理内置命令列表请求
	if key == "gdapi/routes":
		var req := GdApiRequest.new(req_dict)
		var res := GdApiResponse.new(server, id)
		_builtin_routes_handler.handle(req, res)
		return

	# 处理内置 commands 命令
	if key == "gdapi/commands":
		var req_cmd := GdApiRequest.new(req_dict)
		var res_cmd := GdApiResponse.new(server, id)
		_builtin_commands_handler.handle(req_cmd, res_cmd)
		return

	# 处理内置 command-help 命令
	if key == "gdapi/help":
		var req_ch := GdApiRequest.new(req_dict)
		var res_ch := GdApiResponse.new(server, id)
		_builtin_command_help_handler.handle(req_ch, res_ch)
		return

	# 查找注册的命令处理器
	if not _routes.has(key):
		_reply_error(server, id, 404, "route not found: /" + key, "not_found")
		return

	# 实例化处理器并执行
	var handler_script: Script = _routes[key]
	var handler = handler_script.new()

	var req := GdApiRequest.new(req_dict)
	var res := GdApiResponse.new(server, id)

	handler.handle(req, res)

## 发送错误响应
##
## 构建并发送标准格式的错误响应。
## @param server HTTP 服务器实例
## @param id 请求 ID
## @param status HTTP 状态码
## @param msg 错误描述信息
## @param code 错误代码标识符
func _reply_error(server, id: int, status: int, msg: String, code: String) -> void:
	var res := GdApiResponse.new(server, id)
	res.error(msg, code, status)
