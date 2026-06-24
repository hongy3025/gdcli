## 日志级别路由处理器
##
## 提供查询和设置全局日志级别的 API 端点。
## 查询：POST /log/level body: {}
## 设置：POST /log/level body: {"level": "debug"}

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理日志级别请求
##
## 无 body.level 时查询当前级别，有则设置新级别。
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin not available", "plugin_not_ready", 503)
		return

	var plugin = Engine.get_meta("gdapi_plugin")
	var new_level: String = req.get_body("level", "")

	# 查询当前级别
	if new_level.is_empty():
		res.json({
			"ok": true,
			"level": plugin.LOG_LEVEL_NAMES.get(plugin._log_level, "info"),
		})
		return

	# 设置新级别
	var level_map := {"debug": 0, "info": 1, "warn": 2, "error": 3}
	if not level_map.has(new_level.to_lower()):
		res.error("invalid level: " + new_level + ". Use: debug, info, warn, error", "invalid_param", 400)
		return

	plugin._log_level = level_map[new_level.to_lower()]
	res.json({"ok": true, "level": new_level.to_lower()})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("查询或设置全局日志级别") \
		.desc("不带 level 参数时查询当前日志级别；带 level 参数时设置新级别。级别可选：debug, info, warn, error") \
		.param("level", "String", false, "要设置的日志级别（debug/info/warn/error），留空则查询当前级别", "") \
		.returns("查询模式返回当前级别；设置模式返回新级别", {
			"ok": "bool",
			"level": "String, 当前或新设置的日志级别",
		})
