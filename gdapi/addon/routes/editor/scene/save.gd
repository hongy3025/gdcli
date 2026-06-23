@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	var new_path: String = params.get("new_path", "")

	if scene_path.is_empty():
		return {"error": "scene_path is required", "code": "missing_param"}

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		return {"error": "scene not found: " + scene_path, "code": "not_found"}

	var save_path := scene_path
	if not new_path.is_empty():
		if not new_path.begins_with("res://"):
			new_path = "res://" + new_path
		save_path = new_path
		var new_dir := save_path.get_base_dir()
		if new_dir != "res://":
			var abs_dir := ProjectSettings.globalize_path(new_dir)
			if not DirAccess.dir_exists_absolute(abs_dir):
				DirAccess.make_dir_recursive_absolute(abs_dir)

	var scene := load(scene_path)
	if not scene:
		return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

	var save_result := ResourceSaver.save(scene, save_path)
	if save_result != OK:
		return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

	return {
		"ok": true,
		"path": save_path,
	}
