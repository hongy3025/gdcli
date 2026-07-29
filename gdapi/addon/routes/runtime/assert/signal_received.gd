## runtime/assert/signal_received — 等节点信号至少发一次

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/assert/signal_received", false)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("等待节点 signal 至少发送一次")
		. desc("通过临时连接 signal,等到一次性 emit 后断开;超时返回 conflict。")
		. param("node_path", "String", true, "节点路径", "")
		. param("signal", "String", true, "信号名", "")
		. param("timeout_ms", "int", false, "超时毫秒", "1000")
		. example(
			'{"node_path":"/root/RuntimeMain/ProbeTarget","signal":"finished","timeout_ms":500}'
		)
		. returns("结果", {"passed": "bool", "count": "int"})
	)
