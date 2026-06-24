## 路由处理器基类
##
## 所有路由处理器脚本必须继承此基类，并实现 handle 方法。
## 提供统一的接口规范，确保路由系统能够正确调用处理器。
## 通过 GdApiRequest 和 GdApiResponse 对象与请求和响应交互。

@tool
class_name GdApiRouteHandler
extends RefCounted

## 路由处理器基类。所有 routes/**/*.gd 必须 extends 它。
##
## 子类约定：
## - 必须覆盖 handle(req: GdApiRequest, res: GdApiResponse) -> void
## - 通过 res.json() 返回成功响应
## - 通过 res.error() 返回错误响应
## - 不要使用返回值

## 处理请求的虚函数，子类必须实现
##
## @param _req 请求对象，包含请求数据
## @param _res 响应对象，用于发送响应
func handle(_req: GdApiRequest, _res: GdApiResponse) -> void:
	push_error("handler not implemented")
