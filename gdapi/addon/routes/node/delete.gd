## node/delete 路由: 通过 UndoRedo 删除节点

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "node/delete"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	if node_path == "":
		res.error(
			"node_path is required",
			ErrorCodes.MISSING_PARAM,
			ErrorCodes.http_status(ErrorCodes.MISSING_PARAM)
		)
		return
	_send(res, NodeEditor.delete_node(node_path))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		(
			res
			. json(
				{
					"ok": true,
					"changed": true,
					"undoable": true,
					"node_path": result.node_path,
				}
			)
		)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("删除节点并接 UndoRedo")
		. mutates()
		. desc("do: remove_child + queue_free;undo: 重新加入并保留 owner。不可删除场景根节点。")
		. param("node_path", "String", true, "目标节点绝对路径")
		. example('{"node_path":"/root/Main/Icon"}')
		. returns(
			"删除结果",
			{
				"ok": "bool",
				"changed": "bool",
				"undoable": "bool, true",
				"node_path": "String, 被删除节点的路径",
			}
		)
	)
