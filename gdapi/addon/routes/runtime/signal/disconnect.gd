## runtime/signal/disconnect — 断开信号连接

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.signal_disconnect(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "signal/disconnect failed")), String(result.get("code", "godot_error")), 500)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("断开运行期信号连接")
		.desc("必须指定之前 connect 过的 target path + method;若未连接返回 not_found。")
		.param("node_path", "String", true, "源节点路径", "")
		.param("signal", "String", true, "信号名", "")
		.param("target", "String", true, "目标节点路径", "")
		.param("method", "String", true, "目标方法名", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"signal\":\"counted\",\"target\":\"/root/RuntimeMain/ProbeTarget\",\"method\":\"increment\"}")
		.returns("结果", {"disconnected": "bool"})
	)
