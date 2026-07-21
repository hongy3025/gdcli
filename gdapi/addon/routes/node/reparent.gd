## node/reparent 路由: 重新挂接到另一父节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/reparent"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var parent_path: String = req.get_body("parent_path", "")
	if node_path == "" or parent_path == "":
		res.error("node_path and parent_path are required", "missing_param")
		return
	var result := NodeEditor.reparent_node(node_path, parent_path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json({
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": result.node_path,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("把节点挂接到新父节点接 UndoRedo")
		.desc("拒绝把节点挂到自己的后代;新父节点和原父节点必须解析到同一场景有效 Node。")
		.param("node_path", "String", true, "被挂接的节点路径")
		.param("parent_path", "String", true, "新父节点路径")
		.example("{\"node_path\":\"/root/Main/Player/Child\",\"parent_path\":\"/root/Main/Target\"}")
		.returns("reparent 结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String, 重挂接后路径",
		})
	)
