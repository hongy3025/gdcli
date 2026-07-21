## node/signal/list 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/signal/list"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	var lookup := NodeEditor.find(node_path)
	if not lookup.ok:
		res.error(lookup.error, lookup.code, 404)
		return
	var node: Node = lookup.node
	var signal_names: Array = []
	for s in node.get_signal_list():
		signal_names.append(s.name)
	signal_names.sort()
	var connections: Array = []
	for c in node.get_signal_connection_list(""): # placeholder; get_signal_connection_list needs signal name
		pass
	# Iterate signal names then per-signal connections
	var per_signal := {}
	for sname in signal_names:
		var conns: Array = []
		for c in node.get_signal_connection_list(sname):
			var signal_info := {
				"signal": sname,
				"target": _user_path_for(c["callable"].get_object()) if c["callable"].get_object() != null else "",
				"method": c["callable"].get_method(),
				"flags": c["flags"],
			}
			conns.append(signal_info)
		per_signal[sname] = conns
	res.json({
		"ok": true,
		"node_path": lookup.node_path,
		"signals": signal_names,
		"connections": _flatten_connections(node, signal_names),
		"undoable": false,
	})


func _flatten_connections(node: Node, signal_names: Array) -> Array:
	var out: Array = []
	for sname in signal_names:
		for c in node.get_signal_connection_list(sname):
			out.append({
				"signal": sname,
				"target": _user_path_for(c["callable"].get_object()) if c["callable"].get_object() != null else "",
				"method": c["callable"].get_method(),
				"flags": c["flags"],
			})
	return out


static func _user_path_for(node: Node) -> String:
	if not Engine.is_editor_hint():
		return str(node.get_path())
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null or edited == node:
		return "/root/" + String((edited.name if edited != null else "Main"))
	var rel: NodePath = edited.get_path_to(node)
	var rel_str := str(rel).trim_prefix("/")
	if rel_str == "":
		return "/root/" + String(edited.name)
	return "/root/" + String(edited.name) + "/" + rel_str


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出节点的信号和已连接信号")
		.desc("通过 get_signal_list 和 get_signal_connection_list 收集。target 字段已转换为 /root/<edited>/... 用户路径。")
		.param("node_path", "String", true, "节点路径")
		.example("{\"node_path\":\"/root/Main/Player\"}")
		.returns("signal/list", {
			"ok": "bool",
			"node_path": "String",
			"signals": "Array<String>",
			"connections": "Array<{signal,target,method,flags}>",
			"undoable": "bool, false",
		})
	)
