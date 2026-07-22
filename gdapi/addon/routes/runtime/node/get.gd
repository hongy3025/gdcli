## runtime/node/get — 读取运行期节点属性,自动经 VariantCodec 编码

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.get_property(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		res.error(String(result.get("error", "runtime/node/get failed")), code, 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取运行期节点属性")
		.desc("node_path 是绝对路径;property 必须是已声明属性。值通过 VariantCodec 编码,Vector/Color/NodePath/Resource 等会保留 type 字段。")
		.param("node_path", "String", true, "节点路径", "")
		.param("property", "String", true, "属性名", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"property\":\"counter\"}")
		.returns("属性值", {
			"value": "Object, 其中 type 与 value 字段详见 VariantCodec，或纯 plain 值",
		})
	)
