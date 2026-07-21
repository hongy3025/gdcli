## script/detach 路由: 卸下节点脚本 (UndoRedo)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/detach"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	var result := TextEdit.detach_script(node_path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("卸下节点的脚本")
		.desc("UndoRedo 操作: do set_script(null), undo set_script(previous)。无脚本时报 not_found。")
		.param("node_path", "String", true, "节点路径")
		.example("{\"node_path\":\"/root/Main/Player\"}")
		.returns("detach 结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
		})
	)
