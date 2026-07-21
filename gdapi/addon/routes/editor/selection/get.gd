## editor/selection/get 路由: 返回编辑器当前 selection

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ROUTE := "editor/selection/get"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.is_editor_hint():
		res.error("editor only", "not_supported", 400)
		return
	var sel := EditorInterface.get_selection()
	var paths: Array = []
	if sel != null:
		for n in sel.get_selected_nodes():
			paths.append(_user_path(n))
	res.json({
		"ok": true,
		"node_paths": paths,
		"undoable": false,
	})


func _user_path(node: Node) -> String:
	if not Engine.is_editor_hint():
		return str(node.get_path())
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
		GdApiRouteDoc.make("返回编辑器当前选中的节点")
		.desc("返回 EditorInterface.get_selection().get_selected_nodes() 的用户视角路径。")
		.returns("selection", {
			"ok": "bool",
			"node_paths": "Array<String>, 选中节点的 /root/<edited>/... 路径",
			"undoable": "bool, false",
		})
	)
