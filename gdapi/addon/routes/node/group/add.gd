## node/group/add 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

const ROUTE := "node/group/add"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var group: String = req.get_body("group", "")
	var persistent: bool = req.get_body("persistent", true)
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
	if node.is_in_group(group):
		res.error(
			"node already in group: " + group,
			ErrorCodes.CONFLICT,
			ErrorCodes.http_status(ErrorCodes.CONFLICT)
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
	manager.create_action("gdcli: add to group", UndoRedo.MERGE_DISABLE, node)
	manager.add_do_method(node, "add_to_group", group, persistent)
	manager.add_undo_method(node, "remove_from_group", group)
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
				"persistent": persistent,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("节点加入 group")
		. mutates()
		. desc(
			"通过 Node.add_to_group 添加,persistent=true 时落盘保留。重复加入返回 conflict。通过 EditorUndoRedoManager 提交，可撤销。"
		)
		. param("node_path", "String", true, "节点路径")
		. param("group", "String", true, "组名")
		. param("persistent", "bool", false, "是否保存到场景", "true")
		. example('{"node_path":"/root/Main/Target","group":"actors","persistent":true}')
		. returns(
			"group/add",
			{
				"ok": "bool",
				"changed": "bool",
				"undoable": "bool, true",
				"node_path": "String",
				"group": "String",
				"persistent": "bool",
			}
		)
	)
