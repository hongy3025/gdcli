@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	var output_path: String = params.get("output_path", "")
	var mesh_item_names: Array = params.get("mesh_item_names", [])

	if scene_path.is_empty():
		return {"error": "scene_path is required", "code": "missing_param"}
	if output_path.is_empty():
		return {"error": "output_path is required", "code": "missing_param"}

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not output_path.begins_with("res://"):
		output_path = "res://" + output_path

	var scene := load(scene_path)
	if not scene:
		return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

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
		return {"error": "no valid meshes found in scene", "code": "no_meshes"}

	var out_dir := output_path.get_base_dir()
	if out_dir != "res://":
		var abs_dir := ProjectSettings.globalize_path(out_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var save_result := ResourceSaver.save(mesh_library, output_path)
	if save_result != OK:
		return {"error": "failed to save MeshLibrary: " + str(save_result), "code": "save_failed"}

	return {
		"ok": true,
		"output": output_path,
		"item_count": item_id,
	}
