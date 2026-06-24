## 获取 UID 路由处理器
##
## 提供查询资源文件 UID 的 API 端点。
## 读取指定文件的 .uid 文件内容，返回 UID 信息。
## 主要用于资源管理和依赖分析。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理获取 UID 请求
##
## 查找指定资源文件的 .uid 文件，读取并返回其内容。
## @param req 请求对象，包含 file_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var file_path: String = req.get_body("file_path", "")
	if file_path.is_empty():
		res.error("file_path is required", "missing_param")
		return

	# 确保路径以 res:// 开头
	if not file_path.begins_with("res://"):
		file_path = "res://" + file_path

	# 检查文件是否存在
	var abs_path := ProjectSettings.globalize_path(file_path)
	if not FileAccess.file_exists(abs_path):
		res.error("file not found: " + file_path, "not_found", 404)
		return

	# 读取 UID 文件内容
	var uid_path := file_path + ".uid"
	var uid_content := ""
	var uid_exists := false

	if FileAccess.file_exists(uid_path):
		var f := FileAccess.open(uid_path, FileAccess.READ)
		if f:
			uid_content = f.get_as_text().strip_edges()
			f.close()
			uid_exists = true

	# 返回 UID 信息
	res.json({
		"ok": true,
		"file": file_path,
		"absolute_path": abs_path,
		"uid": uid_content,
		"uid_exists": uid_exists,
	})
