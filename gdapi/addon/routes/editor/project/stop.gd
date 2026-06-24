## 停止项目路由处理器
##
## 提供停止当前运行场景的 API 端点。
## 如果当前没有运行中的场景，则返回成功但标记为未运行状态。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理停止运行请求
##
## 检查当前是否有场景正在运行，如果有则停止运行。
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	# 检查是否有场景正在运行
	if not EditorInterface.is_playing_scene():
		res.json({"ok": true, "action": "stop", "message": "not playing"})
		return

	# 停止运行场景
	EditorInterface.stop_playing_scene()

	req.log_info("Stopped playing scene")

	# 返回成功响应
	res.json({"ok": true, "action": "stop"})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("停止当前正在运行的场景") \
		.desc("如果当前有场景正在运行则停止；如果没有运行中的场景则返回成功并标记为未运行状态") \
		.returns("停止结果", {
			"ok": "bool",
			"action": "String, 固定为 stop",
			"message": "String, 仅无运行场景时存在，值为 'not playing'",
		})
