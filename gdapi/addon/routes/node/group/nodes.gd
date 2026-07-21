## node/group/nodes 路由: 列出属于给定 group 的节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/group/nodes"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var group: String = req.get_body("group", "")
	if group == "":
		res.error("group is required", "missing_param")
		return
	if not Engine.is_editor_hint():
		res.error("group/nodes requires editor", "not_supported", 400)
		return
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		res.error("no scene is currently open", "not_found", 404)
		return
	var paths: Array = []
	_collect(edited, group, paths)
	paths.sort()
	res.json({
		"ok": true,
		"group": group,
		"node_paths": paths,
		"undoable": false,
	})


func _collect(node: Node, group: String, out: Array) -> void:
	if node.is_in_group(group):
		out.append(NodeEditor._user_path_for(node))
	for child in node.get_children():
		_collect(child, group, out)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出属于给定 group 的当前编辑场景节点")
		.desc("在当前编辑场景递归 is_in_group。返回 /root/<edited>/... 用户路径。")
		.param("group", "String", true, "组名")
		.example("{\"group\":\"actors\"}")
		.returns("group/nodes", {
			"ok": "bool",
			"group": "String",
			"node_paths": "Array<String>",
			"undoable": "bool, false",
		})
	)
