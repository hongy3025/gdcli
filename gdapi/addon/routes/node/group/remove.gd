## node/group/remove 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

const ROUTE := "node/group/remove"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var group: String = req.get_body("group", "")
	if node_path == "" or group == "":
		res.error(
			"node_path and group are required",
			ErrorCodes.MISSING_PARAM,
			ErrorCodes.http_status(ErrorCodes.MISSING_PARAM)
		)
		return
	var lookup := NodeEditor.find(node_path)
	if not lookup.ok:
		res.error(lookup.error, lookup.code, ErrorCodes.http_status(lookup.code))
		return
	var node: Node = lookup.node
	if not node.is_in_group(group):
		res.error(
			"node not in group: " + group,
			ErrorCodes.NOT_FOUND,
			ErrorCodes.http_status(ErrorCodes.NOT_FOUND)
		)
		return
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error(
			"EditorUndoRedoManager is unavailable",
			ErrorCodes.NOT_SUPPORTED,
			ErrorCodes.http_status(ErrorCodes.NOT_SUPPORTED)
		)
		return
	manager.create_action("gdcli: remove from group", UndoRedo.MERGE_DISABLE, node)
	manager.add_do_method(node, "remove_from_group", group)
	manager.add_undo_method(node, "add_to_group", group, true)
	manager.commit_action()
	(
		res
		. json(
			{
				"ok": true,
				"changed": true,
				"undoable": true,
				"node_path": lookup.node_path,
				"group": group,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("节点退出 group")
		. mutates()
		. desc("通过 Node.remove_from_group。节点不在 group 中返回 not_found。")
		. param("node_path", "String", true, "节点路径")
		. param("group", "String", true, "组名")
		. example('{"node_path":"/root/Main/Target","group":"actors"}')
		. returns(
			"group/remove",
			{
				"ok": "bool",
				"changed": "bool",
				"undoable": "bool, true",
				"node_path": "String",
				"group": "String",
			}
		)
	)
