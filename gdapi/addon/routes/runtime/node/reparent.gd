## runtime/node/reparent — 重新挂载运行期节点

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/reparent", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("重新挂载运行期节点")
		. desc("将 node_path 下的节点挂载到 new_parent 下;拒绝会形成环路的 reparent。")
		. param("node_path", "String", true, "要被移动的节点路径", "")
		. param("new_parent", "String", true, "目标父节点路径", "")
		. example('{"node_path":"/root/RuntimeMain/ProbeTarget","new_parent":"/root/RuntimeMain"}')
		. returns(
			"reparent 结果",
			{
				"new_parent": "String",
				"undoable": "bool, 固定为 false",
			}
		)
	)
