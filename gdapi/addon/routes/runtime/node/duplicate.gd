## runtime/node/duplicate — 复制运行期专用节点

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/duplicate", true)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("复制运行期节点")
		.desc("只允许复制当前场景内的专用节点，并在原父节点下使用不冲突的新名称创建副本。操作不可撤销。")
		.param("node_path", "String", true, "专用源节点绝对路径", "")
		.param("name", "String", true, "副本名称", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"name\":\"Task9Duplicate\"}")
		.returns("复制结果", {
			"node_path": "String, 副本绝对路径",
			"changed": "bool",
			"undoable": "bool, 固定为 false",
		})
	)
