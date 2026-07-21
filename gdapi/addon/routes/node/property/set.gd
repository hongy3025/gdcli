## node/property/set 路由: 设置单个节点属性接 UndoRedo

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/property/set"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var property: String = req.get_body("property", "")
	var value: Variant = req.get_body("value", null)
	if node_path == "" or property == "":
		res.error("node_path and property are required", "missing_param")
		return
	var result := NodeEditor.set_property(node_path, property, value)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("设置节点属性接 UndoRedo")
		.desc("通过 VariantCodec.decode 解码输入,EditAction.commit_property 提交。保留属性 script/source_code 返回 permission_denied。")
		.param("node_path", "String", true, "节点路径")
		.param("property", "String", true, "属性名")
		.param("value", "Variant 编码", true, "Variant 编码字典或裸值")
		.example("{\"node_path\":\"/root/Main/Player\",\"property\":\"position\",\"value\":{\"type\":\"Vector2\",\"value\":[24,32]}}")
		.returns("set 结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
			"property": "String",
			"value": "Variant 编码后的值",
		})
	)
