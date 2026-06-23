@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var project_path: String = params.get("project_path", "res://")
	if not project_path.begins_with("res://"):
		project_path = "res://" + project_path
	if not project_path.ends_with("/"):
		project_path += "/"

	# 查找所有场景文件
	var scenes := _find_files(project_path, ".tscn")
	var scripts := _find_files(project_path, ".gd") + _find_files(project_path, ".shader") + _find_files(project_path, ".gdshader")

	var success_count := 0
	var error_count := 0

	# 重新保存场景以更新 UID
	for scene_path in scenes:
		var scene = load(scene_path)
		if scene:
			var result := ResourceSaver.save(scene, scene_path)
			if result == OK:
				success_count += 1
			else:
				error_count += 1
		else:
			error_count += 1

	# 检查脚本的 UID 文件
	var missing_uids := 0
	var generated_uids := 0

	for script_path in scripts:
		var uid_path := script_path + ".uid"
		if not FileAccess.file_exists(uid_path):
			missing_uids += 1
			var res = load(script_path)
			if res:
				var result := ResourceSaver.save(res, script_path)
				if result == OK:
					generated_uids += 1

	return {
		"ok": true,
		"scenes_processed": scenes.size(),
		"scenes_saved": success_count,
		"scenes_errors": error_count,
		"scripts_missing_uids": missing_uids,
		"uids_generated": generated_uids,
	}

func _find_files(path: String, extension: String) -> Array:
	var files := []
	var dir := DirAccess.open(path)
	if not dir:
		return files

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and not file_name.begins_with("."):
			files.append_array(_find_files(path + file_name + "/", extension))
		elif file_name.ends_with(extension):
			files.append(path + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return files
