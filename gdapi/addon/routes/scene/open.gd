## scene/open 路由: 在编辑器中打开 res:// 路径场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "scene/open"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path.is_empty():
		res.error("path is required", ErrorCodes.MISSING_PARAM)
		return
	var checked := SceneEditor.resolve(path)
	if not checked.ok:
		res.error(checked.error, checked.code, 400)
		return
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_usec() + 5_000_000
	var file_system := EditorInterface.get_resource_filesystem()
	# Filesystem scans are queued; let a pending scan start before testing its state.
	await tree.process_frame
	while file_system.is_scanning() and Time.get_ticks_usec() < deadline:
		await tree.process_frame
	if file_system.is_scanning():
		res.error("editor filesystem scan did not finish before timeout", ErrorCodes.TIMEOUT, 408)
		return
	var scene_was_open := SceneEditor.list_open_scenes().has(checked.path)
	if not scene_was_open:
		var resource := ResourceLoader.load(
			checked.path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE
		)
		if not resource is PackedScene or not resource.can_instantiate():
			res.error("cannot reload scene before opening", ErrorCodes.GODOT_ERROR, 500)
			return
	var result := SceneEditor.open_scene(checked.path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	while SceneEditor.current_path() != result.path and Time.get_ticks_usec() < deadline:
		await tree.process_frame
	if SceneEditor.current_path() != result.path:
		res.error("editor did not open scene before timeout", ErrorCodes.TIMEOUT, 408)
		return
	await tree.process_frame
	(
		res
		. json(
			{
				"ok": true,
				"changed": true,
				"undoable": false,
				"path": result.path,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("在编辑器中打开 res:// 路径场景")
		. mutates()
		. desc("将指定 res:// 场景加载到当前编辑器,替换当前打开的场景(若有)。目标不存在返回 not_found。")
		. param("path", "String", true, "目标场景的 res:// 路径")
		. example('{"path":"res://scenes/main.tscn"}')
		. returns(
			"打开结果",
			{
				"ok": "bool",
				"changed": "bool, 编辑器上下文是否改变",
				"undoable": "bool, 始终为 false",
				"path": "String, 实际打开的 res:// 路径",
			}
		)
	)
