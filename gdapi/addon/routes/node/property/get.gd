## node/property/get 路由: 读取节点属性

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "node/property/get"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var property: String = req.get_body("property", "")
	if node_path == "" or property == "":
		res.error("node_path and property are required", "missing_param")
		return
	var result := NodeEditor.get_property(node_path, property)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取节点属性,Variant 编码为 JSON")
		.desc("通过 VariantCodec.from_variant 把 Vector/Color/NodePath/Resource 编码为带 type 的对象。")
		.param("node_path", "String", true, "节点路径")
		.param("property", "String", true, "属性名,保留属性 script/source_code 拒绝")
		.example("{\"node_path\":\"/root/Main/Player\",\"property\":\"position\"}")
		.returns("属性值", {
			"ok": "bool",
			"node_path": "String",
			"property": "String",
			"value": "Variant 编码后的值",
			"undoable": "bool, false",
		})
	)
