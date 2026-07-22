## runtime/scene/tree — 列出运行期当前场景树
##
## 把 SceneTree.root 序列化为嵌套字典,max_depth 限制递归层数。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理请求:仅一个 max_depth 参数
##
## @param req 请求对象,可选 max_depth(默认 16,最大 32)
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var result: Dictionary = _tree(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		var msg: String = String(result.get("error", "runtime/scene/tree failed"))
		res.error(msg, code, 500, {"details": result})
		return
	res.json(result.get("result", {}))

## 委托给 RuntimeNodeOps.tree
func _tree(payload: Dictionary) -> Dictionary:
	var tree := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	if tree == null:
		return {"ok": false, "code": "godot_error", "error": "node_ops unavailable"}
	return tree.tree(payload)

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询运行期场景树")
		.desc("把 SceneTree.root 序列化为嵌套字典;默认 max_depth=16,可设置 1..32。")
		.param("max_depth", "int", false, "最大递归深度,默认 16", "16")
		.example("{\"max_depth\":2}")
		.returns("场景树", {
			"root": "Object, 含 name/type/path/children",
		})
	)
