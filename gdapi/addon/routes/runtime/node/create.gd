## runtime/node/create — 在运行期场景中创建 allowlisted 节点

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/create", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建运行期节点")
		. desc("只允许在当前场景根节点下创建 allowlist 中的节点类型；properties 使用 VariantCodec 编码。操作不可撤销。")
		. param("parent_path", "String", true, "专用父节点绝对路径", "")
		. param("type", "String", true, "allowlist 节点类型", "Node2D")
		. param("name", "String", true, "新节点名", "")
		. param("properties", "Object", false, "allowlist 属性的 VariantCodec 值", "{}")
		. example('{"parent_path":"/root/RuntimeMain","type":"Node2D","name":"Task9Created"}')
		. returns(
			"创建结果",
			{
				"node_path": "String, 新节点绝对路径",
				"changed": "bool",
				"undoable": "bool, 固定为 false",
			}
		)
	)
