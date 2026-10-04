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
	var result := await _open_validated_scene(checked.path, res)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, int(result.get("status", 400)))


func _open_validated_scene(path: String, res: GdApiResponse) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_usec() + 5_000_000
	var file_system := EditorInterface.get_resource_filesystem()
	var scan_result := await _wait_for_scan(tree, file_system, deadline, res)
	if not scan_result.ok:
		return scan_result
	var scene_was_open := SceneEditor.list_open_scenes().has(path)
	if not scene_was_open:
		var resource := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE)
		if not resource is PackedScene or not resource.can_instantiate():
			return {
				"ok": false,
				"code": ErrorCodes.GODOT_ERROR,
				"status": 500,
				"error": "cannot reload scene before opening",
			}
	var cancelled := _cancellation_error(res)
	if not cancelled.is_empty():
		return cancelled
	if Time.get_ticks_usec() >= deadline:
		return {
			"ok": false,
			"code": ErrorCodes.TIMEOUT,
			"status": 408,
			"error": "scene open timed out before dispatch",
		}
	var result := SceneEditor.open_scene(path)
	if not result.ok:
		return result
	var open_result := await _wait_for_open(tree, result.path, deadline)
	if open_result.ok:
		res.mark_operation_committed(open_result)
	return open_result


func _wait_for_scan(tree: SceneTree, file_system, deadline: int, res: GdApiResponse) -> Dictionary:
	# Filesystem scans are queued; let a pending scan start before testing its state.
	await tree.process_frame
	var cancelled := _cancellation_error(res)
	if not cancelled.is_empty():
		return cancelled
	while file_system.is_scanning() and Time.get_ticks_usec() < deadline:
		await tree.process_frame
		cancelled = _cancellation_error(res)
		if not cancelled.is_empty():
			return cancelled
	if file_system.is_scanning():
		return {
			"ok": false,
			"code": ErrorCodes.TIMEOUT,
			"status": 408,
			"error": "editor filesystem scan did not finish before timeout",
		}
	return {"ok": true}


## After open_scene_from_path is dispatched, wait for the committed editor transition
## instead of converting a later client cancellation into a false failure.
func _wait_for_open(tree: SceneTree, path: String, deadline: int) -> Dictionary:
	while SceneEditor.current_path() != path and Time.get_ticks_usec() < deadline:
		await tree.process_frame
	if SceneEditor.current_path() != path:
		return {
			"ok": false,
			"code": ErrorCodes.TIMEOUT,
			"status": 408,
			"error": "editor did not open scene before timeout",
		}
	await tree.process_frame
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"path": path,
	}


func _cancellation_error(res: GdApiResponse) -> Dictionary:
	var reason := res.cancellation_reason()
	if reason.is_empty():
		return {}
	return {
		"ok": false,
		"error": "handler timeout" if reason == "timeout" else "request cancelled: " + reason,
		"code": "timeout" if reason == "timeout" else "conflict",
		"status": 504 if reason == "timeout" else 409,
	}


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
