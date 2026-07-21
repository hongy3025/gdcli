## node/duplicate 路由: 复制节点接 UndoRedo

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/duplicate"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var name: String = req.get_body("name", "")
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	var result := NodeEditor.duplicate_node(node_path, name)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json({
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": result.node_path,
		"name": result.name,
		"type": result.type,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("复制节点及子结构并接 UndoRedo")
		.desc("采用 Node.DUPLICATE_USE_INSTANTIATION|DUPLICATE_SCRIPTS|DUPLICATE_GROUPS|DUPLICATE_SIGNALS。")
		.param("node_path", "String", true, "源节点路径")
		.param("name", "String", false, "复制节点名,默认 <src>_dup")
		.example("{\"node_path\":\"/root/Main/Player\",\"name\":\"Player2\"}")
		.returns("复制结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String, 复制节点的绝对路径",
			"name": "String",
			"type": "String, 节点类名",
		})
	)
