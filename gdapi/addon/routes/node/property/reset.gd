## node/property/reset 路由: 重置属性到类型默认值

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/property/reset"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var property: String = req.get_body("property", "")
	if node_path == "" or property == "":
		res.error("node_path and property are required", "missing_param")
		return
	var result := NodeEditor.reset_property(node_path, property)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重置属性为类默认值接 UndoRedo")
		.desc("使用 ClassDB.class_get_property_default_value 获取默认值,通过 EditAction.commit_property 提交变更。")
		.param("node_path", "String", true, "节点路径")
		.param("property", "String", true, "属性名")
		.example("{\"node_path\":\"/root/Main/Player\",\"property\":\"position\"}")
		.returns("reset 结果", {
			"ok": "bool",
			"changed": "bool, 是否与之前的值不同",
			"undoable": "bool, true",
			"node_path": "String",
			"property": "String",
			"value": "Variant 编码后的默认值",
		})
	)
