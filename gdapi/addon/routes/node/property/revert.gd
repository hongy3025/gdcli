## node/property/revert 路由: 还原属性 (与 reset 等价)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/property/revert"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var property: String = req.get_body("property", "")
	if node_path == "" or property == "":
		res.error("node_path and property are required", "missing_param")
		return
	var result := NodeEditor.revert_property(node_path, property)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("还原节点属性到默认值")
		.desc("M2 范围内与 reset 等价;后续与 inspector history 集成时可改为还原到打开场景时的值。")
		.param("node_path", "String", true, "节点路径")
		.param("property", "String", true, "属性名")
		.example("{\"node_path\":\"/root/Main/Player\",\"property\":\"position\"}")
		.returns("revert 结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
			"property": "String",
			"value": "Variant 编码后的默认值",
		})
	)
