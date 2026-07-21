## node/select 路由: 选中节点 (EditorInterface selection)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "node/select"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var paths_v: Variant = req.get_body("node_paths", [])
	var clear: bool = req.get_body("clear", true)
	if typeof(paths_v) != TYPE_ARRAY:
		res.error("node_paths must be an array", ErrorCodes.INVALID_PARAM)
		return
	if clear and Engine.is_editor_hint():
		EditorInterface.get_selection().clear()
	var resolved: Array = []
	for raw in paths_v:
		var lookup := NodeEditor.find(str(raw))
		if not lookup.ok:
			res.error(lookup.error, lookup.code, 404)
			return
		resolved.append(lookup.node)
	for n in resolved:
		EditorInterface.get_selection().add_node(n)
	res.json({
		"ok": true,
		"changed": not resolved.is_empty() or clear,
		"undoable": false,
		"node_paths": NodeEditor.select_user_paths(resolved),
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("选中一个或多个节点")
		.desc("默认先清空编辑器已有 selection,再按 node_paths 顺序选中。clear=false 时在现有选择上叠加。")
		.param("node_paths", "Array<String>", false, "节点路径列表,留空表示清空")
		.param("clear", "bool", false, "是否先清空已有 selection", "true")
		.example("{\"node_paths\":[\"/root/Main/Player\"]}")
		.returns("选择结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, false",
			"node_paths": "Array<String>, 实际选中的节点路径",
		})
	)
