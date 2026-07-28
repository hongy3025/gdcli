## runtime/node/get — 读取运行期节点属性,自动经 VariantCodec 编码

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/get")

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取运行期节点属性")
		.desc("node_path 是绝对路径;property 必须是已声明属性。值通过 VariantCodec 编码,Vector/Color/NodePath/Resource 等会保留 type 字段。")
		.param("node_path", "String", true, "节点路径", "")
		.param("property", "String", true, "属性名", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"property\":\"counter\"}")
		.returns("属性值", {
			"value": "VariantCodec 对象（例如 Vector2 为 {type, value}），或 plain 值",
		})
	)
