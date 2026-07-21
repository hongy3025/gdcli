## node/signal/disconnect 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "node/signal/disconnect"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var source_path: String = req.get_body("source_path", "")
	var signal_name: String = req.get_body("signal", "")
	var target_path: String = req.get_body("target_path", "")
	var method: String = req.get_body("method", "")
	if source_path == "" or signal_name == "" or target_path == "" or method == "":
		res.error("source_path, signal, target_path and method are required", ErrorCodes.MISSING_PARAM)
		return
	var source_lookup := NodeEditor.find(source_path)
	if not source_lookup.ok:
		res.error(source_lookup.error, source_lookup.code, 404)
		return
	var target_lookup := NodeEditor.find(target_path)
	if not target_lookup.ok:
		res.error(target_lookup.error, target_lookup.code, 404)
		return
	var source: Node = source_lookup.node
	var target: Node = target_lookup.node
	var found := false
	for c in source.get_signal_connection_list(signal_name):
		if c["callable"].get_object() == target and c["callable"].get_method() == method:
			found = true
			break
	if not found:
		res.error("connection not found", ErrorCodes.NOT_FOUND, 404)
		return
	source.disconnect(signal_name, Callable(target, method))
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"source_path": source_lookup.node_path,
		"signal": signal_name,
		"target_path": target_lookup.node_path,
		"method": method,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("断开节点信号与目标方法的连接")
		.desc("未找到现有连接返回 not_found。")
		.param("source_path", "String", true, "源节点路径")
		.param("signal", "String", true, "信号名")
		.param("target_path", "String", true, "目标节点路径")
		.param("method", "String", true, "目标方法名")
		.example("{\"source_path\":\"/root/Main/Player\",\"signal\":\"health_changed\",\"target_path\":\"/root/Main/Target\",\"method\":\"_on_health_changed\"}")
		.returns("disconnect", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, false",
		})
	)
