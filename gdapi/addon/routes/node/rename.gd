## node/rename 路由: 节点改名接 UndoRedo

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/rename"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var name: String = req.get_body("name", "")
	if node_path == "" or name == "":
		res.error("node_path and name are required", "missing_param")
		return
	var result := NodeEditor.rename_node(node_path, name)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json({
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": result.node_path,
		"name": result.name,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重命名节点接 UndoRedo")
		.desc("通过 EditAction.commit_property 提交 name 属性,自动避开兄弟节点同名。")
		.param("node_path", "String", true, "节点路径")
		.param("name", "String", true, "新节点名")
		.example("{\"node_path\":\"/root/Main/Icon\",\"name\":\"Avatar\"}")
		.returns("重命名结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String, 重命名后路径",
			"name": "String, 最终使用的名称",
		})
	)
