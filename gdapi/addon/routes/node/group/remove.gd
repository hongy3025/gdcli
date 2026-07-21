## node/group/remove 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "node/group/remove"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var group: String = req.get_body("group", "")
	if node_path == "" or group == "":
		res.error("node_path and group are required", ErrorCodes.MISSING_PARAM)
		return
	var lookup := NodeEditor.find(node_path)
	if not lookup.ok:
		res.error(lookup.error, lookup.code, 404)
		return
	var node: Node = lookup.node
	if not node.is_in_group(group):
		res.error("node not in group: " + group, ErrorCodes.NOT_FOUND, 404)
		return
	node.remove_from_group(group)
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"node_path": lookup.node_path,
		"group": group,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("节点退出 group")
		.desc("通过 Node.remove_from_group。节点不在 group 中返回 not_found。")
		.param("node_path", "String", true, "节点路径")
		.param("group", "String", true, "组名")
		.example("{\"node_path\":\"/root/Main/Target\",\"group\":\"actors\"}")
		.returns("group/remove", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, false",
			"node_path": "String",
			"group": "String",
		})
	)
