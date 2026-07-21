## 获取 UID 路由处理器
##
## 提供查询资源文件 UID 的 API 端点。
## 读取指定文件的 .uid 文件内容，返回 UID 信息。
## 主要用于资源管理和依赖分析。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")

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

	# 使用 PathGuard 校验路径
	var checked := PathGuard.validate(file_path, "read")
	if not checked.ok:
		res.error(checked.error, checked.code, checked.status)
		return
	file_path = checked.path

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
## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询资源文件的 UID")
		.desc("读取指定资源文件的 .uid 文件内容，返回 UID 信息；用于资源管理和依赖分析")
		.param("file_path", "String", true, "资源文件路径，可省略 res:// 前缀")
		.example("{\"file_path\":\"res://test.tscn\"}")
		.returns("文件路径、绝对路径和 UID 信息", {
			"ok": "bool",
			"file": "String, 资源路径",
			"absolute_path": "String, 全局绝对路径",
			"uid": "String, UID 内容（不存在时为空字符串）",
			"uid_exists": "bool, UID 文件是否存在",
		})
	)
