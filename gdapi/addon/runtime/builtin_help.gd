## 内置帮助路由
##
## POST /help            → 返回所有路由的简要列表（path + summary + params 名/required）
## POST /help {path:"x"} → 返回路由 x 的完整帮助文档
##
## 路由表由 router.scan() 完成后调用 set_routes() 注入。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 完整路由表：{ path: handler_script }，由 router 注入
var _routes: Dictionary = {}

## 由 router 在扫描完成后调用，传入完整路由表（含 ping/routes/help 等内置项）
##
## @param routes 路由表字典
func set_routes(routes: Dictionary) -> void:
	_routes = routes

## 处理 /help 请求
##
## 无 body.path → 返回列表；带 body.path → 返回该路由的完整文档；
## 路径不存在 → 404 not_found。
##
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")

	if path.is_empty():
		res.json({"ok": true, "routes": _build_list()})
		return

	if not _routes.has(path):
		res.error("route not found: " + path, "not_found", 404)
		return

	var handler = _routes[path].new()
	var detail: Dictionary = handler.doc().to_dict()
	detail["path"] = path
	res.json({"ok": true, "doc": detail})

## 构建路由简要列表
##
## 对每个注册路由实例化 handler，调用 doc().to_summary_dict() 并补上 path 字段。
## 路由按字母序排序。
##
## @return 排序后的简要路由信息数组
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
## @return GdApiRouteDoc 描述 /help 路由的语义
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出可用路由或查询单个路由的帮助文档")
		.desc("不带 path 参数返回所有路由的简要列表；带 path 参数返回该路由的完整文档")
		.param("path", "String", false, "要查询的路由路径，留空返回全部路由列表", "")
		.returns("列表模式返回 routes 数组；详情模式返回 doc 对象", {
			"ok": "bool, 是否成功",
			"routes": "Array, 仅列表模式存在",
			"doc": "Dictionary, 仅详情模式存在",
		})
	)
