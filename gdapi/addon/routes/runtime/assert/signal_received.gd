## runtime/assert/signal_received — 等节点信号至少发一次

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = await ops.assert_signal_received(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "assert/signal_received failed")), String(result.get("code", "conflict")), 409)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("等待节点 signal 至少发送一次")
		.desc("通过临时连接 signal,等到一次性 emit 后断开;超时返回 conflict。")
		.param("node_path", "String", true, "节点路径", "")
		.param("signal", "String", true, "信号名", "")
		.param("timeout_ms", "int", false, "超时毫秒", "1000")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"signal\":\"finished\",\"timeout_ms\":500}")
		.returns("结果", {"passed": "bool", "count": "int"})
	)
