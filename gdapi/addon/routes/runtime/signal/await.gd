## runtime/signal/await — 一次等待运行期信号发送

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = await ops.signal_await(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		var status: int = 500
		if code == "timeout":
			status = 408
		res.error(String(result.get("error", "signal/await failed")), code, status)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("等待运行期信号发送一次")
		.desc("通过临时连接 signal,等到第一次 emit 后断开;超时返回 408 timeout。")
		.param("node_path", "String", true, "节点路径", "")
		.param("signal", "String", true, "信号名", "")
		.param("timeout_ms", "int", false, "超时毫秒", "1000")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"signal\":\"finished\",\"timeout_ms\":500}")
		.returns("结果", {"signal": "String"})
	)
