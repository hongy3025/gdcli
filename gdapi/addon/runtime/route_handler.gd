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

func handle(_req: GdApiRequest, _res: GdApiResponse) -> void:
	push_error("handler not implemented")
