## runtime/node/remove — 删除运行期节点(queue_free)
##
## 不能删除 /root、当前场景根或 probe autoload。

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/remove", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("删除运行期节点(异步 queue_free)")
		. mutates()
		. desc(
			"通过 queue_free 释放节点,不能删除 SceneTree.root,也不能删除当前 probe 持有的节点。操作不可撤销,固定返回 undoable:false。"
		)
		. param("node_path", "String", true, "节点路径", "")
		. example('{"node_path":"/root/RuntimeMain/TempNode"}')
		. returns(
			"删除结果",
			{
				"removed": "String, 被删除节点原本的路径",
				"undoable": "bool, 固定为 false",
			}
		)
	)
