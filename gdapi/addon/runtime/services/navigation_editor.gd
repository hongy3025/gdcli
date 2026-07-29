@tool
class_name GdApiNavigationEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")


static func list_regions() -> Dictionary:
	var root := SceneEditor.current_root()
	if root == null:
		return _error(ErrorCodes.NOT_FOUND, "no scene is currently open")
	var regions: Array = []
	_collect_regions(root, regions)
	regions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	return {"ok": true, "regions": regions, "undoable": false}


static func bake(region_path: Variant, path: Variant, force: Variant) -> Dictionary:
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
	var target := ProjectSettings.globalize_path(checked.path)
	if FileAccess.file_exists(target) and (typeof(force) != TYPE_BOOL or not force):
		AuditLog.record(
			"navigation/mesh/bake",
			"dangerous",
			{"path": checked.path, "force": false},
			false,
			ErrorCodes.UNSAFE_OPERATION
		)
		return _error(
			ErrorCodes.UNSAFE_OPERATION,
			"navigation/mesh/bake requires force:true for an existing target"
		)
	var copy: NavigationPolygon = polygon.duplicate(true)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var error := ResourceSaver.save(copy, checked.path)
	if error != OK:
		return _error(ErrorCodes.GODOT_ERROR, "failed to save navigation polygon")
	AuditLog.record(
		"navigation/mesh/bake",
		"file",
		{"region_path": region_path, "path": checked.path, "force": force},
		true
	)
	return {
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": checked.path,
		"region_path": region_path
	}


static func _collect_regions(node: Node, output: Array) -> void:
	if node is NavigationRegion2D:
		var root := SceneEditor.current_root()
		var relative := String(root.get_path_to(node)) if root != null else String(node.name)
		output.append(
			{
				"path": "/root/" + String(root.name) + "/" + relative.trim_prefix("/"),
				"class": "NavigationRegion2D",
				"map_rid": str((node as NavigationRegion2D).get_navigation_map())
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
