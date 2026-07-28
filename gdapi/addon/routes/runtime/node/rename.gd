## runtime/node/rename — 重命名运行期专用节点

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/rename", true)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("重命名运行期节点")
		.desc("只允许重命名当前场景中的专用节点；名称不能为空、含路径分隔符、覆盖保护节点或与兄弟节点冲突。操作不可撤销。")
		.param("node_path", "String", true, "专用节点绝对路径", "")
		.param("name", "String", true, "新节点名", "")
		.example("{\"node_path\":\"/root/RuntimeMain/Task9Duplicate\",\"name\":\"Task9Renamed\"}")
		.returns("重命名结果", {
			"node_path": "String, 新节点绝对路径",
			"changed": "bool",
			"undoable": "bool, 固定为 false",
		})
	)
