## node/group/list 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/group/list"

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
	var groups: Array = []
	for g in node.get_groups():
		groups.append(g)
	groups.sort()
	res.json({
		"ok": true,
		"node_path": lookup.node_path,
		"groups": groups,
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出节点所属的所有 group")
		.desc("包括 persistent:true 的保存组和当前非持久组。")
		.param("node_path", "String", true, "节点路径")
		.example("{\"node_path\":\"/root/Main/Target\"}")
		.returns("group/list", {
			"ok": "bool",
			"node_path": "String",
			"groups": "Array<String>",
			"undoable": "bool, false",
		})
	)
