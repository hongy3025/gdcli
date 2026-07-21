## script/attach 路由: 附加脚本到节点 (UndoRedo)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/attach"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var path: String = req.get_body("path", "")
	if node_path == "" or path == "":
		res.error("node_path and path are required", "missing_param")
		return
	var result := TextEdit.attach_script(node_path, path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("挂接脚本到节点")
		.desc("通过 EditorUndoRedoManager 提交 set_script;可 undo/redo。脚本必须是 res:// 路径下的 .gd Script 资源。")
		.param("node_path", "String", true, "节点路径")
		.param("path", "String", true, "脚本 res:// 路径")
		.example("{\"node_path\":\"/root/Main/Player\",\"path\":\"res://scripts/player.gd\"}")
		.returns("attach 结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
			"script_path": "String",
		})
	)
