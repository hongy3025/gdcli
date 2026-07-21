## node/get 路由: 读取节点摘要

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/get"

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
	res.json({
		"ok": true,
		"node_path": lookup.node_path,
		"name": node.name,
		"type": node.get_class(),
		"scene_file_path": node.scene_file_path,
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("按 NodePath 读取节点摘要")
		.desc("返回 name / type / scene_file_path;路径无效返回 not_found;仅编辑场景内有效。")
		.param("node_path", "String", true, "绝对节点路径,如 /root/Main/Player")
		.example("{\"node_path\":\"/root/Main/Player\"}")
		.returns("节点信息", {
			"ok": "bool",
			"node_path": "String",
			"name": "String",
			"type": "String",
			"scene_file_path": "String",
			"undoable": "bool, 始终为 false",
		})
	)
