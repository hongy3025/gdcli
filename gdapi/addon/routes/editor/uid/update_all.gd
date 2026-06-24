## 更新所有 UID 路由处理器
##
## 提供批量更新项目中所有资源 UID 的 API 端点。
## 扫描指定目录下的场景文件和脚本文件，重新保存以生成或更新 UID。
## 主要用于解决 UID 缺失或损坏导致的资源引用问题。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理更新所有 UID 请求
##
## 扫描项目目录，重新保存场景文件以更新 UID，
## 并为缺少 UID 的脚本文件生成新的 UID。
## @param req 请求对象，包含可选的 project_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var project_path: String = req.get_body("project_path", "res://")
	if not project_path.begins_with("res://"):
		project_path = "res://" + project_path
	if not project_path.ends_with("/"):
		project_path += "/"

	# 查找所有场景和脚本文件
	var scenes := _find_files(project_path, ".tscn")
	var scripts := _find_files(project_path, ".gd") + _find_files(project_path, ".shader") + _find_files(project_path, ".gdshader")

	# 处理场景文件
	var success_count := 0
	var error_count := 0

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

	# 处理脚本文件，生成缺失的 UID
	var missing_uids := 0
	var generated_uids := 0

	for script_path in scripts:
		var uid_path: String = script_path + ".uid"
		if not FileAccess.file_exists(uid_path):
			missing_uids += 1
			var res_load = load(script_path)
			if res_load:
				var result := ResourceSaver.save(res_load, script_path)
				if result == OK:
					generated_uids += 1

	# 返回处理结果统计
	res.json({
		"ok": true,
		"scenes_processed": scenes.size(),
		"scenes_saved": success_count,
		"scenes_errors": error_count,
		"scripts_missing_uids": missing_uids,
		"uids_generated": generated_uids,
	})

## 递归查找指定扩展名的文件
##
## @param path 要搜索的目录路径
## @param extension 文件扩展名（如 ".tscn", ".gd"）
## @return 匹配的文件路径数组
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
