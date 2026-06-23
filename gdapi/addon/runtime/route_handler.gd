@tool
class_name GdApiRouteHandler
extends RefCounted

## 路由处理器基类。所有 routes/**/*.gd 必须 extends 它。
##
## 子类约定：
## - 必须覆盖 handle(params: Dictionary) -> Dictionary
## - 成功时返回 {"ok": true, ...}
## - 失败时返回 {"error": "...", "code": "...", "details": {...}}
## - status_code 默认：含 error 字段 → 500，否则 200

func handle(_params: Dictionary) -> Dictionary:
    return {"error": "handler not implemented"}

func status_code(result: Dictionary) -> int:
    return 500 if result.has("error") else 200
