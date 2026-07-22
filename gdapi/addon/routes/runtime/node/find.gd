## runtime/node/find — 在运行期场景树中按 name/type/group 查找节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.find(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "find failed")), String(result.get("code", "godot_error")), 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("在运行期场景树中查找节点")
		.desc("支持按 name/type/group 任意组合过滤,limit 默认 32,最大 200。从 SceneTree.root 开始深度优先。")
		.param("name", "String", false, "节点名", "")
		.param("type", "String", false, "ClassDB 类型名,如 Node2D", "")
		.param("group", "String", false, "group 名", "")
		.param("limit", "int", false, "最多返回数量,默认 32", "32")
		.example("{\"name\":\"ProbeTarget\"}")
		.returns("查找结果", {
			"nodes": "Array, 每项含 path/type/name",
			"total": "int",
		})
	)
