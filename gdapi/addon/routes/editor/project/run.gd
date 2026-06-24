## 运行项目路由处理器
##
## 提供运行 Godot 场景的 API 端点。
## 支持运行主场景或指定路径的自定义场景。
## 用于自动化测试和快速预览场景。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理运行场景请求
##
## 根据请求参数运行主场景或指定场景。
## 如果未提供 scene_path，则运行主场景；否则运行指定路径的场景。
## @param req 请求对象，包含可选的 scene_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")

	# 如果未指定场景路径，运行主场景
	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		req.log_info("Started playing main scene")
		res.json({"ok": true, "action": "play_main_scene"})
		return

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# 检查场景文件是否存在
	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, "not_found", 404)
		return

	# 运行指定场景
	EditorInterface.play_custom_scene(scene_path)

	req.log_info("Started playing scene: " + scene_path)

	# 返回成功响应
	res.json({"ok": true, "action": "play_custom_scene", "scene": scene_path})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("运行 Godot 场景") \
		.desc("不带 scene_path 时运行主场景；带 scene_path 时运行指定路径的自定义场景；用于自动化测试和快速预览") \
		.param("scene_path", "String", false, "要运行的场景路径，留空则运行主场景", "") \
		.returns("运行结果", {
			"ok": "bool",
			"action": "String, play_main_scene 或 play_custom_scene",
			"scene": "String, 仅自定义场景模式存在，运行的场景路径",
		})
