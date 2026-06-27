## 内置路由列表处理器
##
## 提供 /routes 端点，返回所有已注册的路由名称列表。
## 用于客户端发现可用的 API 端点。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 已注册的路由名称列表
var _route_names: Array = []
var _route_meta: Dictionary = {}
var _alias_to_canonical: Dictionary = {}

## 设置路由名称列表
##
## 由路由器在扫描完成后调用，设置所有可用路由的名称。
## @param names 路由名称数组
func set_route_names(names: Array) -> void:
	_route_names = names

func set_route_meta(route_meta: Dictionary, alias_to_canonical: Dictionary) -> void:
	_route_meta = route_meta
	_alias_to_canonical = alias_to_canonical

## 处理路由列表请求
##
## 返回所有已注册路由的名称列表。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({
		"ok": true,
		"routes": _route_names,
		"aliases": _alias_to_canonical,
		"meta": _route_meta,
	})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出所有已注册的路由名称")
		.desc("返回当前 gdapi 运行时所有可调用路由的扁平名称数组；用于客户端发现 API 端点")
		.returns("路由名数组（含内置 ping / routes / help）", {
			"ok": "bool",
			"routes": "Array[String], 按字母序排列的路由路径",
		})
	)
