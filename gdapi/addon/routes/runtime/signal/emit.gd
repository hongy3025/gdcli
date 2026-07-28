## runtime/signal/emit — 在运行期主动 emit 信号

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.signal_emit(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "signal/emit failed")), String(result.get("code", "godot_error")), 500)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("主动 emit 运行期信号")
		.desc("目标节点必须声明该 signal;args 最多 4 个 literal。")
		.param("node_path", "String", true, "源节点路径", "")
		.param("signal", "String", true, "信号名", "")
		.param("args", "Array", false, "0..4 个位置参数", "[]")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"signal\":\"finished\"}")
		.returns("结果", {"emitted": "String", "arg_count": "int"})
	)
