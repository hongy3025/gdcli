## runtime/node/reparent — 重新挂载运行期节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.reparent(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		res.error(String(result.get("error", "reparent failed")), code, 500)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重新挂载运行期节点")
		.desc("将 node_path 下的节点挂载到 new_parent 下;拒绝会形成环路的 reparent。")
		.param("node_path", "String", true, "要被移动的节点路径", "")
		.param("new_parent", "String", true, "目标父节点路径", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"new_parent\":\"/root/RuntimeMain\"}")
		.returns("reparent 结果", {
			"new_parent": "String",
			"undoable": "bool, 固定为 false",
		})
	)
