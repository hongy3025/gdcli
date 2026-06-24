## 停止项目路由处理器
##
## 提供停止当前运行场景的 API 端点。
## 如果当前没有运行中的场景，则返回成功但标记为未运行状态。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理停止运行请求
##
## 检查当前是否有场景正在运行，如果有则停止运行。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	# 检查是否有场景正在运行
	if not EditorInterface.is_playing_scene():
		res.json({"ok": true, "action": "stop", "message": "not playing"})
		return

	# 停止运行场景
	EditorInterface.stop_playing_scene()

	# 记录日志
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Stopped playing scene", "info")

	# 返回成功响应
	res.json({"ok": true, "action": "stop"})
