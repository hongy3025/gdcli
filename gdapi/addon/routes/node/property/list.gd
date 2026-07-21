## node/property/list 路由: 列出节点属性

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/property/list"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	var result := NodeEditor.list_properties(node_path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出节点的属性 schema")
		.desc("通过 get_property_list() 获取每个属性的 name/type/usage,排除 CATEGORY 与下划线开头的非编辑属性,按 name 排序。")
		.param("node_path", "String", true, "节点路径")
		.example("{\"node_path\":\"/root/Main/Player\"}")
		.returns("属性列表", {
			"ok": "bool",
			"node_path": "String",
			"properties": "Array<{name,type,usage}>",
			"undoable": "bool, false",
		})
	)
