## runtime/signal/connect — 连接运行期信号(allowlist 限制 target method)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.signal_connect(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "signal/connect failed")), String(result.get("code", "godot_error")), 500)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("连接运行期信号")
		.desc("目标方法必须在 target 节点的 gdapi_callable_methods allowlist 中;非 allowlist 方法返回 permission_denied。")
		.param("node_path", "String", true, "源节点路径", "")
		.param("signal", "String", true, "信号名", "")
		.param("target", "String", true, "目标节点路径", "")
		.param("method", "String", false, "目标方法名,默认 _on_signal", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"signal\":\"counted\",\"target\":\"/root/RuntimeMain/ProbeTarget\",\"method\":\"increment\"}")
		.returns("结果", {"connected": "bool", "signal": "String"})
	)
