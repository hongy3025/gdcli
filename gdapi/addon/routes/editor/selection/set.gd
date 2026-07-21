## editor/selection/set 路由: 设置编辑器 selection

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")

const ROUTE := "editor/selection/set"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var paths_v: Variant = req.get_body("node_paths", [])
	var clear: bool = req.get_body("clear", true)
	if typeof(paths_v) != TYPE_ARRAY:
		res.error("node_paths must be an array", ErrorCodes.INVALID_PARAM)
		return
	# 预解析所有路径,任一无效则不修改 selection
	var resolved: Array = []
	for raw in paths_v:
		var lookup := NodeEditor.find(str(raw))
		if not lookup.ok:
			res.error(lookup.error, lookup.code, 404)
			return
		resolved.append(lookup.node)
	if clear and Engine.is_editor_hint():
		EditorInterface.get_selection().clear()
	for n in resolved:
		EditorInterface.get_selection().add_node(n)
	var result_paths: Array = []
	for n in resolved:
		result_paths.append(_user_path_for(n))
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"node_paths": result_paths,
	})


static func _user_path_for(node: Node) -> String:
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null or edited == node:
		return "/root/" + String((edited.name if edited != null else "Main"))
	var rel: NodePath = edited.get_path_to(node)
	var rel_str := str(rel).trim_prefix("/")
	if rel_str == "":
		return "/root/" + String(edited.name)
	return "/root/" + String(edited.name) + "/" + rel_str


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("设置编辑器 selection")
		.desc("默认先清空,再按 node_paths 顺序添加。clear=false 时叠加。任一路径无效返回 not_found,不修改 selection。")
		.param("node_paths", "Array<String>", false, "节点路径列表,留空表示清空")
		.param("clear", "bool", false, "是否先清空已有 selection", "true")
		.example("{\"node_paths\":[\"/root/Main/Player\",\"/root/Main/Target\"]}")
		.returns("selection", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, false",
			"node_paths": "Array<String>",
		})
	)
