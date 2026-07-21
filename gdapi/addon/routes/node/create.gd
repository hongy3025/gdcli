## node/create 路由: 创建新节点并接 UndoRedo

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/create"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var parent_path: String = req.get_body("parent_path", "")
	var type: String = req.get_body("type", "")
	var name: String = req.get_body("name", "")
	if parent_path == "" or type == "":
		res.error("parent_path and type are required", "missing_param")
		return
	var result := NodeEditor.create_node(parent_path, type, name)
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
		GdApiRouteDoc.make("在指定父节点下创建节点")
		.desc("使用 EditorUndoRedoManager 提交 add_child + set_owner 组合,可 undo/redo。仅支持 Node 子类类型;name 自动避开冲突。")
		.param("parent_path", "String", true, "父节点绝对路径,如 /root/Main")
		.param("type", "String", true, "节点类型,必须存在且为 Node 子类")
		.param("name", "String", false, "新节点名,留空自动生成")
		.example("{\"parent_path\":\"/root/Main\",\"type\":\"Sprite2D\",\"name\":\"Icon\"}")
		.returns("创建结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"undoable": "bool, true",
			"node_path": "String, 新节点的绝对路径",
			"name": "String, 最终的节点名",
			"type": "String, 节点类名",
		})
	)
