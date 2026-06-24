## 内置路由列表处理器
##
## 提供 /routes 端点，返回所有已注册的路由名称列表。
## 用于客户端发现可用的 API 端点。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 已注册的路由名称列表
var _route_names: Array = []

## 设置路由名称列表
##
## 由路由器在扫描完成后调用，设置所有可用路由的名称。
## @param names 路由名称数组
func set_route_names(names: Array) -> void:
	_route_names = names

## 处理路由列表请求
##
## 返回所有已注册路由的名称列表。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({"ok": true, "routes": _route_names})
