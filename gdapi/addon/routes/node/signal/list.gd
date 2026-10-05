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
	(
		res
		. json(
			{
				"ok": true,
				"node_path": lookup.node_path,
				"signals": signal_names,
				"connections": _flatten_connections(node, signal_names),
				"undoable": false,
			}
		)
	)


func _flatten_connections(node: Node, signal_names: Array) -> Array:
	var out: Array = []
	for sname in signal_names:
		for c in node.get_signal_connection_list(sname):
			var callable: Callable = c["callable"]
			var target := _connection_target(callable)
			(
				out
				. append(
					{
						"signal": sname,
						"target": target.path,
						"target_class": target.class_name,
						"method": callable.get_method(),
						"flags": c["flags"],
					}
				)
			)
	return out


## 连接目标不一定是场景内节点：编辑器自身会给被选中的节点接上内部对象
## （例如 EditorSelection），这类目标没有可寻址节点路径，只能报告其类名。
func _connection_target(callable: Callable) -> Dictionary:
	var object := callable.get_object()
	if object == null:
		return {"path": "", "class_name": ""}
	if not object is Node:
		return {"path": "", "class_name": object.get_class()}
	var target: Node = object
	var edited := EditorInterface.get_edited_scene_root()
	if edited != null and (target == edited or edited.is_ancestor_of(target)):
		return {"path": _user_path_for(target), "class_name": target.get_class()}
	return {"path": str(target.get_path()), "class_name": target.get_class()}


static func _user_path_for(node: Node) -> String:
	if not Engine.is_editor_hint():
		return str(node.get_path())
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		return str(node.get_path())
	if edited == node:
		return "/root/" + String(edited.name)
	var rel: NodePath = edited.get_path_to(node)
	var rel_str := str(rel).trim_prefix("/")
	if rel_str == "":
		return "/root/" + String(edited.name)
	return "/root/" + String(edited.name) + "/" + rel_str


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出节点的信号和已连接信号")
		. desc(
			(
				"通过 get_signal_list 和 get_signal_connection_list 收集。"
				+ "场景内 target 为 /root/<edited>/... 用户路径；场景外节点为其真实树路径；"
				+ "非节点目标(如编辑器内部对象)target 为空并给出 target_class。"
			)
		)
		. param("node_path", "String", true, "节点路径")
		. example('{"node_path":"/root/Main/Player"}')
		. returns(
			"signal/list",
			{
				"ok": "bool",
				"node_path": "String",
				"signals": "Array<String>",
				"connections": "Array<{signal,target,target_class,method,flags}>",
				"undoable": "bool, false",
			}
		)
	)
