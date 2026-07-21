## node/group/add 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "node/group/add"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var group: String = req.get_body("group", "")
	var persistent: bool = req.get_body("persistent", true)
	if node_path == "" or group == "":
		res.error("node_path and group are required", ErrorCodes.MISSING_PARAM)
		return
	var lookup := NodeEditor.find(node_path)
	if not lookup.ok:
		res.error(lookup.error, lookup.code, 404)
		return
	var node: Node = lookup.node
	if node.is_in_group(group):
		res.error("node already in group: " + group, ErrorCodes.CONFLICT, 409)
		return
	node.add_to_group(group, persistent)
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"node_path": lookup.node_path,
		"group": group,
		"persistent": persistent,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("节点加入 group")
		.desc("通过 Node.add_to_group 添加,persistent=true 时落盘保留。重复加入返回 conflict。")
		.param("node_path", "String", true, "节点路径")
		.param("group", "String", true, "组名")
		.param("persistent", "bool", false, "是否保存到场景", "true")
		.example("{\"node_path\":\"/root/Main/Target\",\"group\":\"actors\",\"persistent\":true}")
		.returns("group/add", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, false",
			"node_path": "String",
			"group": "String",
			"persistent": "bool",
		})
	)
