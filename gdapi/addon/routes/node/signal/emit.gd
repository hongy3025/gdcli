## node/signal/emit 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "node/signal/emit"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var source_path: String = req.get_body("source_path", "")
	var signal_name: String = req.get_body("signal", "")
	var args_v: Variant = req.get_body("arguments", [])
	if source_path == "" or signal_name == "":
		res.error("source_path and signal are required", ErrorCodes.MISSING_PARAM)
		return
	var source_lookup := NodeEditor.find(source_path)
	if not source_lookup.ok:
		res.error(source_lookup.error, source_lookup.code, 404)
		return
	var source: Node = source_lookup.node
	if not source.has_signal(signal_name):
		res.error("signal not found", ErrorCodes.NOT_FOUND, 404)
		return
	# 只能转发简单 args (这里简化: 不在编辑器信号上 emit 复杂 args)
	if typeof(args_v) != TYPE_ARRAY:
		res.error("arguments must be an array", ErrorCodes.INVALID_PARAM)
		return
	var callable := Callable(source, "emit_signal")
	var result: Variant = source.emit_signal(signal_name)
	res.json({
		"ok": true,
		"changed": false,
		"undoable": false,
		"source_path": source_lookup.node_path,
		"signal": signal_name,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("在编辑器中触发节点信号 (不可撤销)")
		.desc("通过 source.emit_signal 同步派发,仅对无参信号有意义;参数信号请通过编辑器 inspector 编辑。")
		.param("source_path", "String", true, "源节点路径")
		.param("signal", "String", true, "信号名")
		.param("arguments", "Array", false, "参数(M2 不序列化)", "[]")
		.returns("emit", {
			"ok": "bool",
			"changed": "bool, false",
			"undoable": "bool, false",
			"source_path": "String",
			"signal": "String",
		})
	)
