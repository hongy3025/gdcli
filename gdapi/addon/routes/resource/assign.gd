## resource/assign 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/assign"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var property: String = req.get_body("property", "")
	var path: String = req.get_body("path", "")
	if node_path == "" or property == "" or path == "":
		res.error("node_path, property and path are required", "missing_param")
		return
	var result := ResourceEditor.assign(node_path, property, path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("将 Resource 赋给节点的属性 (UndoRedo)")
		.desc("通过 set/UndoRedo 提交,可 undo/redo。仅支持属性类型为 Resource 或其子类的字段。")
		.param("node_path", "String", true, "目标节点路径")
		.param("property", "String", true, "属性名")
		.param("path", "String", true, "资源 res:// 路径")
		.example("{\"node_path\":\"/root/Main/Player\",\"property\":\"texture\",\"path\":\"res://icon.svg\"}")
		.returns("assign", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
			"property": "String",
			"path": "String",
		})
	)
