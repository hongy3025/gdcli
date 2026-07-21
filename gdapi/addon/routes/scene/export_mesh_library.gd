## 导出网格库路由处理器
##
## 提供从场景导出 MeshLibrary 资源的 API 端点。
## 支持从场景中的 MeshInstance3D 节点提取网格和碰撞形状。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "scene/export_mesh_library"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var output_path: String = req.get_body("output_path", "")
	var mesh_item_names: Array = req.get_body("mesh_item_names", [])
	var force: bool = req.get_body("force", false)

	if scene_path.is_empty():
		res.error("scene_path is required", ErrorCodes.MISSING_PARAM)
		return
	if output_path.is_empty():
		res.error("output_path is required", ErrorCodes.MISSING_PARAM)
		return

	# 校验路径
	var checked := PathGuard.validate(scene_path, "read")
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, checked.code)
		res.error(checked.error, checked.code, checked.status)
		return
	scene_path = checked.path

	checked = PathGuard.validate(output_path, "write")
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"output": output_path}, false, checked.code)
		res.error(checked.error, checked.code, checked.status)
		return
	output_path = checked.path

	# 目标已存在时要求 force
	if FileAccess.file_exists(ProjectSettings.globalize_path(output_path)):
		if not ErrorCodes.require_force(res, force, ROUTE):
			AuditLog.record(ROUTE, "dangerous", {"target": output_path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
			return

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to load scene: " + scene_path, ErrorCodes.GODOT_ERROR, 500)
		return

	var scene_root: Node = scene.instantiate()
	var mesh_library := MeshLibrary.new()
	var item_id := 0
	var use_specific := mesh_item_names.size() > 0

	for child in scene_root.get_children():
		if use_specific and not (child.name in mesh_item_names):
			continue

		var mesh_instance: MeshInstance3D = null
		if child is MeshInstance3D:
			mesh_instance = child
		else:
			for descendant in child.get_children():
				if descendant is MeshInstance3D:
					mesh_instance = descendant
					break

		if mesh_instance and mesh_instance.mesh:
			mesh_library.create_item(item_id)
			mesh_library.set_item_name(item_id, child.name)
			mesh_library.set_item_mesh(item_id, mesh_instance.mesh)

			for collision_child in child.get_children():
				if collision_child is CollisionShape3D and collision_child.shape:
					mesh_library.set_item_shapes(item_id, [collision_child.shape])
					break

			item_id += 1

	if item_id == 0:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.NOT_FOUND)
		res.error("no valid meshes found in scene", ErrorCodes.NOT_FOUND, 400)
		return

	var out_dir := output_path.get_base_dir()
	if out_dir != "res://":
		var abs_dir := ProjectSettings.globalize_path(out_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var save_result := ResourceSaver.save(mesh_library, output_path)
	if save_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"output": output_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to save MeshLibrary: " + str(save_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": save_result})
		return

	AuditLog.record(ROUTE, "dangerous", {"source": scene_path, "output": output_path, "item_count": item_id}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"output": output_path,
		"item_count": item_id,
	})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("从场景导出 MeshLibrary 资源")
		.desc("从场景中的 MeshInstance3D 节点提取网格和碰撞形状，生成 MeshLibrary 资源")
		.param("scene_path", "String", true, "源场景路径")
		.param("output_path", "String", true, "MeshLibrary 输出路径")
		.param("force", "bool", false, "输出目标已存在时需为 true")
		.param("mesh_item_names", "Array", false, "要导出的网格项名称列表，留空则导出所有", [])
		.example("{\"scene_path\":\"res://test.tscn\",\"output_path\":\"res://test.meshlib\",\"force\":true}")
		.returns("导出结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"saved": "bool, 是否已保存到磁盘",
			"undoable": "bool, 始终为 false",
			"output": "String, 输出路径",
			"item_count": "int, 导出的网格项数",
		})
	)
