@tool
class_name GdApiNavigationEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

## 主线程同步烘焙后等待异步任务的兜底上限；超过即视为失败并清理输出。
const BAKE_TIMEOUT_MSEC := 10000


static func list_regions() -> Dictionary:
	var root := SceneEditor.current_root()
	if root == null:
		return _error(ErrorCodes.NOT_FOUND, "no scene is currently open")
	var regions: Array = []
	_collect_regions(root, regions)
	regions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	return {"ok": true, "regions": regions, "undoable": false}


static func bake(region_path: Variant, path: Variant) -> Dictionary:
	if typeof(region_path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "region_path must be a string")
	var root := SceneEditor.current_root()
	if root == null:
		return _error(ErrorCodes.NOT_FOUND, "no scene is currently open")
	var region := _resolve(root, String(region_path))
	if not region is NavigationRegion2D:
		return _error(ErrorCodes.NOT_FOUND, "NavigationRegion2D not found")
	var polygon: NavigationPolygon = (region as NavigationRegion2D).navigation_polygon
	if polygon == null:
		return _error(ErrorCodes.NOT_FOUND, "navigation polygon not found")
	var checked := _resource_path(path)
	if not checked.ok:
		return checked
	var target := String(checked.path)
	if not (region as NavigationRegion2D).is_inside_tree():
		_remove_output(target)
		return _error(ErrorCodes.GODOT_ERROR, "navigation region is not inside the scene tree")
	var baked := _bake_polygon(polygon, region as NavigationRegion2D)
	if baked == null:
		_remove_output(target)
		return _error(ErrorCodes.GODOT_ERROR, "navigation bake produced no polygons")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target).get_base_dir())
	var error := ResourceSaver.save(baked, target)
	if error != OK:
		_remove_output(target)
		return _error(ErrorCodes.GODOT_ERROR, "failed to save navigation polygon")
	AuditLog.record(
		"navigation/mesh/bake", "file", {"region_path": region_path, "path": target}, true
	)
	return {
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": target,
		"region_path": region_path,
		"vertex_count": baked.vertices.size(),
		"polygon_count": baked.polygons.size()
	}


## 解析当前源几何并烘焙出全新的 NavigationPolygon；失败/超时返回 null。
static func _bake_polygon(
	source: NavigationPolygon, region: NavigationRegion2D
) -> NavigationPolygon:
	var baked: NavigationPolygon = source.duplicate(true)
	var source_geometry := NavigationMeshSourceGeometryData2D.new()
	NavigationServer2D.parse_source_geometry_data(source, source_geometry, region)
	NavigationServer2D.bake_from_source_geometry_data(baked, source_geometry)
	var deadline := Time.get_ticks_msec() + BAKE_TIMEOUT_MSEC
	while NavigationServer2D.is_baking_navigation_polygon(baked):
		if Time.get_ticks_msec() >= deadline:
			return null
		OS.delay_msec(1)
	if baked.get_polygon_count() == 0:
		return null
	return baked


## 失败时清理输出，避免留下半成品文件。
static func _remove_output(path: String) -> void:
	for candidate in [path, path + ".uid"]:
		var absolute := ProjectSettings.globalize_path(candidate)
		if FileAccess.file_exists(absolute):
			DirAccess.remove_absolute(absolute)


static func _collect_regions(node: Node, output: Array) -> void:
	if node is NavigationRegion2D:
		var region := node as NavigationRegion2D
		var polygon: NavigationPolygon = region.navigation_polygon
		var root := SceneEditor.current_root()
		var relative := String(root.get_path_to(node)) if root != null else String(node.name)
		output.append(
			{
				"path": "/root/" + String(root.name) + "/" + relative.trim_prefix("/"),
				"class": "NavigationRegion2D",
				"vertex_count": polygon.vertices.size() if polygon != null else 0,
				"polygon_count": polygon.polygons.size() if polygon != null else 0
			}
		)
	for child in node.get_children():
		_collect_regions(child, output)


static func _resolve(root: Node, path: String) -> Node:
	var prefix := "/root/" + String(root.name)
	if path == prefix:
		return root
	if path.begins_with(prefix + "/"):
		return root.get_node_or_null(NodePath(path.trim_prefix(prefix + "/")))
	return root.get_node_or_null(NodePath(path.trim_prefix("/")))


static func _resource_path(path: Variant) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "path must be a string")
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return _error(checked.code, checked.error)
	if (
		not String(checked.path).begins_with("res://")
		or not String(checked.path).ends_with(".tres")
	):
		return _error(ErrorCodes.INVALID_PATH, "navigation bake path must be project-local .tres")
	return checked


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
