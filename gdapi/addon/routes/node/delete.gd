## node/delete 路由: 通过 UndoRedo 删除节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/delete"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	var result := NodeEditor.delete_node(node_path)
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
		GdApiRouteDoc.make("删除节点并接 UndoRedo")
		.desc("do: remove_child + queue_free;undo: 重新加入并保留 owner。不可删除场景根节点。")
		.param("node_path", "String", true, "目标节点绝对路径")
		.example("{\"node_path\":\"/root/Main/Icon\"}")
		.returns("删除结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String, 被删除节点的路径",
		})
	)
