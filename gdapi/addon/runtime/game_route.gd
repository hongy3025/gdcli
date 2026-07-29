## M4 游戏系统 route 的 runtime broker adapter。
##
## 公开 path 始终是领域 route；子类只能提供固定 m4/** internal operation，
## 不能从客户端 body 接受 operation 名称。

@tool
class_name GdApiGameRoute
extends "res://addons/gdapi/runtime/runtime_route.gd"

func dispatch_game(req: GdApiRequest, res: GdApiResponse, operation: String, mutation: bool = false) -> void:
	if not operation.begins_with("m4/") or operation.trim_prefix("m4/").is_empty():
		res.error("invalid M4 internal operation", "invalid_param", 400)
		return
	var public_route := req.path.trim_prefix("/") if req != null else ""
	dispatch(req, res, operation, mutation, public_route)
