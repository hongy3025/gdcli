## 导出网格库路由处理器
##
## 提供从场景导出 MeshLibrary 资源的 API 端点。
## 支持从场景中的 MeshInstance3D 节点提取网格和碰撞形状，
## 生成可用于 GridMap 等节点的网格库资源。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理网格库导出请求
##
## 从指定场景中提取网格实例，创建 MeshLibrary 资源并保存。
## 支持指定要导出的网格项名称，或导出所有网格。
## @param req 请求对象，包含 scene_path、output_path 和可选的 mesh_item_names
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var output_path: String = req.get_body("output_path", "")
	var mesh_item_names: Array = req.get_body("mesh_item_names", [])

	# 验证必需参数
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if output_path.is_empty():
		res.error("output_path is required", "missing_param")
		return

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not output_path.begins_with("res://"):
		output_path = "res://" + output_path

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	# 实例化场景并创建网格库
	var scene_root := scene.instantiate()

	var mesh_library := MeshLibrary.new()
	var item_id := 0
	var use_specific := mesh_item_names.size() > 0

	# 遍历场景子节点提取网格
	for child in scene_root.get_children():
		# 如果指定了名称列表，只处理指定的节点
		if use_specific and not (child.name in mesh_item_names):
			continue

		# 查找 MeshInstance3D 节点
		var mesh_instance: MeshInstance3D = null
		if child is MeshInstance3D:
			mesh_instance = child
		else:
			# 在子节点中查找
			for descendant in child.get_children():
				if descendant is MeshInstance3D:
					mesh_instance = descendant
					break

		# 如果找到有效的网格实例，添加到网格库
		if mesh_instance and mesh_instance.mesh:
			mesh_library.create_item(item_id)
			mesh_library.set_item_name(item_id, child.name)
			mesh_library.set_item_mesh(item_id, mesh_instance.mesh)

			# 查找碰撞形状
			for collision_child in child.get_children():
				if collision_child is CollisionShape3D and collision_child.shape:
					mesh_library.set_item_shapes(item_id, [collision_child.shape])
					break

			item_id += 1

	# 检查是否找到有效的网格
	if item_id == 0:
		res.error("no valid meshes found in scene", "no_meshes", 400)
		return

	# 创建输出目录（如果不存在）
	var out_dir := output_path.get_base_dir()
	if out_dir != "res://":
		var abs_dir := ProjectSettings.globalize_path(out_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	# 保存网格库资源
	var save_result := ResourceSaver.save(mesh_library, output_path)
	if save_result != OK:
		res.error("failed to save MeshLibrary: " + str(save_result), "save_failed", 500)
		return

	# 返回成功响应
	res.json({
		"ok": true,
		"output": output_path,
		"item_count": item_id,
	})
