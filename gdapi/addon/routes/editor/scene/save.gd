## 场景保存路由处理器
##
## 提供保存 Godot 场景文件的 API 端点。
## 支持保存当前场景或另存为新路径，自动创建不存在的目录。
## 主要用于自动化工作流和批量场景处理。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理场景保存请求
##
## 支持两种模式：
## 1. 保存到原路径（只提供 scene_path）
## 2. 另存为新路径（同时提供 scene_path 和 new_path）
## @param req 请求对象，包含 scene_path 和可选的 new_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var new_path: String = req.get_body("new_path", "")

	# 验证必需参数
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# 检查场景文件是否存在
	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, "not_found", 404)
		return

	# 确定保存路径
	var save_path := scene_path
	if not new_path.is_empty():
		if not new_path.begins_with("res://"):
			new_path = "res://" + new_path
		save_path = new_path
		# 自动创建目标目录
		var new_dir := save_path.get_base_dir()
		if new_dir != "res://":
			var abs_dir := ProjectSettings.globalize_path(new_dir)
			if not DirAccess.dir_exists_absolute(abs_dir):
				DirAccess.make_dir_recursive_absolute(abs_dir)

	# 加载场景资源
	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	# 保存场景到指定路径
	var save_result := ResourceSaver.save(scene, save_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	# 返回成功响应
	res.json({
		"ok": true,
		"path": save_path,
	})
