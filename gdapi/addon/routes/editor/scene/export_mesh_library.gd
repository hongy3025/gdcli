@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var output_path: String = req.get_body("output_path", "")
	var mesh_item_names: Array = req.get_body("mesh_item_names", [])

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if output_path.is_empty():
		res.error("output_path is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not output_path.begins_with("res://"):
		output_path = "res://" + output_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

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
		res.error("no valid meshes found in scene", "no_meshes", 400)
		return

	var out_dir := output_path.get_base_dir()
	if out_dir != "res://":
		var abs_dir := ProjectSettings.globalize_path(out_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var save_result := ResourceSaver.save(mesh_library, output_path)
	if save_result != OK:
		res.error("failed to save MeshLibrary: " + str(save_result), "save_failed", 500)
		return

	res.json({
		"ok": true,
		"output": output_path,
		"item_count": item_id,
	})
