## runtime/node/remove — 删除运行期节点(queue_free)
##
## 不能删除 /root、当前场景根或 probe autoload。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.remove(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		res.error(String(result.get("error", "remove failed")), code, 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("删除运行期节点(异步 queue_free)")
		.desc("通过 queue_free 释放节点,不能删除 SceneTree.root,也不能删除当前 probe 持有的节点。操作不可撤销,固定返回 undoable:false。")
		.param("node_path", "String", true, "节点路径", "")
		.example("{\"node_path\":\"/root/RuntimeMain/TempNode\"}")
		.returns("删除结果", {
			"removed": "String, 被删除节点原本的路径",
			"undoable": "bool, 固定为 false",
		})
	)
