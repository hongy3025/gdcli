## node/list 路由: 列出节点的直接子节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/list"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		node_path = "/root"
	var result := NodeEditor.list_children(node_path)
	if not result.ok:
		res.error(result.error, result.code, 404)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出节点直接子节点")
		.desc("返回按节点顺序排列的子节点摘要数组;node_path 省略时默认 /root 编辑根。")
		.param("node_path", "String", false, "父节点路径,默认 /root")
		.example("{\"node_path\":\"/root/Main\"}")
		.returns("子节点列表", {
			"ok": "bool",
			"node_path": "String",
			"children": "Array<{name,path,type}>",
			"undoable": "bool, false",
		})
	)
