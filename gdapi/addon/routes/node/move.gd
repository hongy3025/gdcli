## node/move 路由: 在同一父节点下移动节点顺序

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/move"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var target_path: String = req.get_body("target_path", "")
	var position: String = req.get_body("position", "after")
	if node_path == "" or target_path == "":
		res.error("node_path and target_path are required", "missing_param")
		return
	if position not in ["before", "after"]:
		res.error("position must be 'before' or 'after'", "invalid_param")
		return
	var result := NodeEditor.move_node(node_path, target_path, position)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json({
		"ok": true,
		"changed": result.changed,
		"undoable": result.undoable,
		"node_path": result.node_path,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("调整 sibling index 接 UndoRedo")
		.desc("在同一父节点下将 node 排到 target 的 before/after;否则返回 invalid_param。")
		.param("node_path", "String", true, "被移动节点路径")
		.param("target_path", "String", true, "锚点节点路径,必须与 node 共享同一父节点")
		.param("position", "String", false, "before 或 after,默认 after")
		.example("{\"node_path\":\"/root/Main/Target\",\"target_path\":\"/root/Main/Player\",\"position\":\"after\"}")
		.returns("移动结果", {
			"ok": "bool",
			"changed": "bool, false 表示已是目标位置",
			"undoable": "bool",
			"node_path": "String",
		})
	)
