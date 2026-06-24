## 路由系统核心模块
##
## 负责扫描、注册和分发 HTTP 请求到对应的路由处理器。
## 支持自动扫描目录下的 GDScript 文件作为路由处理器，提供内置路由（如 ping 和路由列表）。
## 使用路径匹配机制，将请求路径映射到处理器脚本。

@tool
extends RefCounted

## 请求类预加载引用
const GdApiRequest := preload("res://addons/gdapi/runtime/request.gd")
## 响应类预加载引用
const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")
## 内置 ping 路由处理器
const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
## 内置路由列表处理器
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")
## 内置帮助路由处理器
const BuiltinHelp := preload("res://addons/gdapi/runtime/builtin_help.gd")

## 路由注册表，键为路径（如 "editor/scene/save"），值为处理器脚本
var _routes: Dictionary = {}
## 内置路由列表处理器实例
var _builtin_routes_handler: BuiltinRoutes
## 内置帮助路由处理器实例
var _builtin_help_handler: BuiltinHelp

## 扫描并注册路由处理器
##
## 清空现有路由，注册内置路由，然后递归扫描指定目录下的所有 .gd 文件。
## 扫描范围包括 editor 和 shared 两个子目录，分别对应编辑器专用和共享路由。
## @param root_dir 路由处理器根目录路径
func scan(root_dir: String) -> void:
	_routes.clear()
	_routes["ping"] = BuiltinPing
	_builtin_routes_handler = BuiltinRoutes.new()
	_builtin_help_handler = BuiltinHelp.new()
	_scan_dir(root_dir + "/editor", "")
	_scan_dir(root_dir + "/shared", "")
	var names: Array = _routes.keys()
	names.append("routes")
	names.append("help")
	names.sort()
	_builtin_routes_handler.set_route_names(names)

	# 把所有路由（含内置）注入到 help handler
	var all_routes: Dictionary = _routes.duplicate()
	all_routes["routes"] = BuiltinRoutes
	all_routes["help"] = BuiltinHelp
	_builtin_help_handler.set_routes(all_routes)

## 获取已注册路由总数
##
## 包含内置的 ping 路由。
## @return 路由数量
func count() -> int:
	# _routes 已含 ping；额外两个内置路由：routes + help
	return _routes.size() + 2

## 递归扫描目录注册路由
##
## 递归遍历目录，将所有 .gd 文件注册为路由处理器。
## 文件名（去掉 .gd 后缀）作为路由名称，子目录名作为路径前缀。
## 以 _ 开头的文件会被忽略。
## @param dir_path 要扫描的目录路径
## @param prefix 路径前缀（用于构建完整路由路径）
func _scan_dir(dir_path: String, prefix: String) -> void:
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
			_scan_dir(full, sub_prefix)
		elif name.ends_with(".gd") and not name.begins_with("_"):
			var route_name := name.substr(0, name.length() - 3)
			var key := (prefix + "/" + route_name) if prefix != "" else route_name
			var script: Script = load(full) as Script
			if script != null:
				_routes[key] = script
		name = dir.get_next()
	dir.list_dir_end()

## 分发请求到对应的路由处理器
##
## 根据请求路径查找处理器并执行。支持以下特殊路由：
## - /routes：返回所有可用路由列表
## - /ping：内置健康检查路由
## 其他路径会查找注册的处理器脚本并实例化执行。
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

	# 处理内置路由列表请求
	if key == "routes":
		var req := GdApiRequest.new(req_dict)
		var res := GdApiResponse.new(server, id)
		_builtin_routes_handler.handle(req, res)
		return

	# 处理内置 help 路由
	if key == "help":
		var req_help := GdApiRequest.new(req_dict)
		var res_help := GdApiResponse.new(server, id)
		_builtin_help_handler.handle(req_help, res_help)
		return

	# 查找注册的路由处理器
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
