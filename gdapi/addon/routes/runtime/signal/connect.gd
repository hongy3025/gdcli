## runtime/signal/connect — 连接运行期信号(allowlist 限制 target method)

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/signal/connect", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("连接运行期信号")
		. mutates()
		. desc(
			"目标方法必须在 target 节点的 gdapi_callable_methods allowlist 中;非 allowlist 方法返回 permission_denied。"
		)
		. param("node_path", "String", true, "源节点路径", "")
		. param("signal", "String", true, "信号名", "")
		. param("target", "String", true, "目标节点路径", "")
		. param("method", "String", false, "目标方法名,默认 _on_signal", "")
		. example(
			(
				'{"node_path":"/root/RuntimeMain/ProbeTarget","signal":"counted",'
				+ '"target":"/root/RuntimeMain/ProbeTarget","method":"increment"}'
			)
		)
		. returns("结果", {"connected": "bool", "signal": "String"})
	)
