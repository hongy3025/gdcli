## 内置命令列表路由
##
## POST `command/list` → 返回所有可用命令的详细列表（path + summary + params）
##
## 路由表由 router.scan() 完成后调用 set_routes() 注入。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 完整路由表：{ path: handler_script }，由 router 注入
var _routes: Dictionary = {}

## 由 router 在扫描完成后调用，传入完整路由表
##
## @param routes 路由表字典
func set_routes(routes: Dictionary) -> void:
	_routes = routes

## 处理 `command/list` 请求
##
## 返回所有命令的详细列表。
##
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({"ok": true, "commands": _build_list()})

## 构建命令详细列表
##
## 对每个注册路由实例化 handler，调用 doc().to_summary_dict() 并补上 path 字段。
## 命令按字母序排序。
##
## @return 排序后的命令信息数组
func _build_list() -> Array:
	var result: Array = []
	var keys: Array = _routes.keys()
	keys.sort()
	for key in keys:
		var handler = _routes[key].new()
		var summary: Dictionary = handler.doc().to_summary_dict()
		summary["path"] = key
		result.append(summary)
	return result

## 自身的帮助文档
##
## @return GdApiRouteDoc 描述 `command/list` 路由的语义
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出所有可用命令的详细信息")
		.desc("返回当前 gdapi 运行时所有可调用命令的详细列表，包含参数信息")
		.returns("命令信息数组", {
			"ok": "bool, 是否成功",
			"commands": "Array, 按字母序排列的命令信息",
		})
	)
