## runtime/signal/emit — 在运行期主动 emit 信号

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/signal/emit", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("主动 emit 运行期信号")
		. mutates()
		. desc("目标节点必须声明该 signal;args 最多 4 个 literal。")
		. param("node_path", "String", true, "源节点路径", "")
		. param("signal", "String", true, "信号名", "")
		. param("args", "Array", false, "0..4 个位置参数", "[]")
		. example('{"node_path":"/root/RuntimeMain/ProbeTarget","signal":"finished"}')
		. returns("结果", {"emitted": "String", "arg_count": "int"})
	)
