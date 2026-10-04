## node/signal/connect 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

const ROUTE := "node/signal/connect"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var source_path: String = req.get_body("source_path", "")
	var signal_name: String = req.get_body("signal", "")
	var target_path: String = req.get_body("target_path", "")
	var method: String = req.get_body("method", "")
	var flags: int = int(req.get_body("flags", Object.CONNECT_PERSIST))
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error(
			"EditorUndoRedoManager is unavailable",
			ErrorCodes.NOT_SUPPORTED,
			ErrorCodes.http_status(ErrorCodes.NOT_SUPPORTED)
		)
		return
	if source_path == "" or signal_name == "" or target_path == "" or method == "":
		res.error(
			"source_path, signal, target_path and method are required",
			ErrorCodes.MISSING_PARAM,
			ErrorCodes.http_status(ErrorCodes.MISSING_PARAM)
		)
		return
	var source_lookup := NodeEditor.find(source_path)
	if not source_lookup.ok:
		res.error(
			source_lookup.error, source_lookup.code, ErrorCodes.http_status(source_lookup.code)
		)
		return
	var target_lookup := NodeEditor.find(target_path)
	if not target_lookup.ok:
		res.error(
			target_lookup.error, target_lookup.code, ErrorCodes.http_status(target_lookup.code)
		)
		return
	var source: Node = source_lookup.node
	var target: Node = target_lookup.node
	var err: String = ""
	if not source.has_signal(signal_name):
		err = "signal not found on source: " + signal_name
	elif not target.has_method(method):
		err = "method not found on target: " + method
	if err != "":
		res.error(err, ErrorCodes.NOT_FOUND, ErrorCodes.http_status(ErrorCodes.NOT_FOUND))
		return
	# 检查重复连接
	for c in source.get_signal_connection_list(signal_name):
		if c["callable"].get_object() == target and c["callable"].get_method() == method:
			res.error(
				"connection already exists",
				ErrorCodes.CONFLICT,
				ErrorCodes.http_status(ErrorCodes.CONFLICT)
			)
			return
	manager.create_action("gdcli: connect signal", UndoRedo.MERGE_DISABLE, source)
	manager.add_do_method(source, "connect", signal_name, Callable(target, method), flags)
	manager.add_undo_method(source, "disconnect", signal_name, Callable(target, method))
	manager.commit_action()
	(
		res
		. json(
			{
				"ok": true,
				"changed": true,
				"undoable": true,
				"source_path": source_lookup.node_path,
				"signal": signal_name,
				"target_path": target_lookup.node_path,
				"method": method,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("连接节点信号到目标方法")
		. mutates()
		. desc(
			"默认 flags=CONNECT_PERSIST。重复连接到同一 callable 返回 conflict。通过 EditorUndoRedoManager 提交，可撤销。"
		)
		. param("source_path", "String", true, "源节点路径")
		. param("signal", "String", true, "信号名")
		. param("target_path", "String", true, "目标节点路径")
		. param("method", "String", true, "目标方法名")
		. param("flags", "int", false, "ConnectFlags,默认 CONNECT_PERSIST")
		. example(
			(
				'{"source_path":"/root/Main/Player","signal":"health_changed",'
				+ '"target_path":"/root/Main/Target","method":"_on_health_changed"}'
			)
		)
		. returns(
			"connect",
			{
				"ok": "bool",
				"changed": "bool",
				"undoable": "bool, true",
				"source_path": "String",
				"signal": "String",
				"target_path": "String",
				"method": "String",
			}
		)
	)
