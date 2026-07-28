## runtime/node/set — 设置运行期节点属性

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/set", true)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("设置运行期节点属性")
		.desc("通过 VariantCodec 解码 value,写入对应属性。返回值含 undoable:false 表示该操作不会被 Godot 的 UndoRedo 系统记录。")
		.param("node_path", "String", true, "节点路径", "")
		.param("property", "String", true, "属性名", "")
		.param("value", "Object", true, "Variant 编码后的值", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"property\":\"counter\",\"value\":{\"plain\":7}}")
		.returns("设置结果", {
			"changed": "bool",
			"undoable": "bool, 固定为 false",
			"property": "String",
		})
	)
