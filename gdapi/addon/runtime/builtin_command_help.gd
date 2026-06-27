## 内置命令帮助路由
##
## POST /command-help {command:"path"} → 返回指定命令的完整帮助文档
##
## 路由表由 router.scan() 完成后调用 set_routes() 注入。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 完整路由表：{ path: handler_script }，由 router 注入
var _routes: Dictionary = {}
var _route_meta: Dictionary = {}

## 由 router 在扫描完成后调用，传入完整路由表
##
## @param routes 路由表字典
func set_routes(routes: Dictionary) -> void:
	_routes = routes

func set_route_meta(route_meta: Dictionary) -> void:
	_route_meta = route_meta

func _apply_meta(path: String, doc: Dictionary) -> Dictionary:
	var meta: Dictionary = _route_meta.get(path, {"canonical_path": path, "aliases": [], "is_alias": false})
	doc["path"] = path
	doc["canonical_path"] = meta.get("canonical_path", path)
	doc["aliases"] = meta.get("aliases", [])
	doc["is_alias"] = meta.get("is_alias", false)
	return doc

## 处理 /command-help 请求
##
## 必须提供 command 参数，返回该命令的完整文档；
## 命令不存在 → 404 not_found。
##
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var command: String = req.get_body("command", "")

	if command.is_empty():
		res.error("missing required parameter: command", "invalid_request", 400)
		return

	if not _routes.has(command):
		res.error("command not found: " + command, "not_found", 404)
		return

	var handler = _routes[command].new()
	var detail: Dictionary = _apply_meta(command, handler.doc().to_dict())
	res.json({"ok": true, "doc": detail})

## 自身的帮助文档
##
## @return GdApiRouteDoc 描述 /command-help 路由的语义
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询单个命令的详细帮助文档")
		.desc("返回指定命令的完整文档，包含参数、返回值和示例")
		.param("command", "String", true, "要查询的命令路径", "")
		.returns("命令详细文档", {
			"ok": "bool, 是否成功",
			"doc": "Dictionary, 命令完整文档",
		})
	)
