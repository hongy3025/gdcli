## 停止项目路由处理器
##
## 提供停止当前运行场景的 API 端点。
## 如果当前没有运行中的场景，则返回成功但标记为未运行状态。
## M3: 停止前调用 runtime broker.detach("game stopped"),
##      把所有 pending 请求同步失败回调,让等待中的 await/call 立刻收到 conflict。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")


## 处理停止运行请求
##
## 检查当前是否有场景正在运行，如果有则停止运行。
## @param req 请求对象
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	# 先停止场景，再 detach broker。
	# 顺序很重要：wait_stopped() 依赖 broker 状态判断停服完成，
	# 但 EditorInterface.is_playing_scene() 可能异步返回 false。
	# 如果先 detach 再 stop_playing_scene，wait_stopped 可能在
	# 场景还在运行时就返回，导致后续 project_run 的 play_main_scene 无效果。
	var broker: Variant = RuntimeBroker.instance()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		# 等待场景真正停止（最多 10 秒）
		var deadline: int = Time.get_ticks_msec() + 10000
		while Time.get_ticks_msec() < deadline and EditorInterface.is_playing_scene():
			pass  # 忙等，不 yield 以避免路由协程复杂度
	if broker != null:
		broker.detach("game stopped")

	(
		res
		. json(
			{
				"ok": true,
				"action": "stop",
				"runtime_state": "stopped",
			}
		)
	)


## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("停止当前正在运行的场景")
		. mutates()
		. desc("如果当前有场景正在运行则停止；如果没有运行中的场景则返回成功并标记为未运行状态。M3 同时让所有在途 pending 请求同步收到 conflict")
		. returns(
			"停止结果",
			{
				"ok": "bool",
				"action": "String, 固定为 stop",
				"message": "String, 仅无运行场景时存在，值为 'not playing'",
				"runtime_state": "String, 固定为 stopped",
			}
		)
	)
