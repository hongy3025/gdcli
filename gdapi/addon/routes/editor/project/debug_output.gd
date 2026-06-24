## 调试输出路由处理器
##
## 提供获取编辑器日志输出的 API 端点。
## 支持增量获取日志条目，用于实时监控编辑器输出。
## 主要用于调试和日志收集场景。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理调试输出请求
##
## 从插件日志缓冲区获取指定序列号之后的日志条目。
## 支持分页和增量获取，避免重复获取已读日志。
## @param req 请求对象，包含可选的 since（起始序列号）和 limit（最大条目数）
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var since: int = req.get_body("since", 0)
	var limit: int = req.get_body("limit", 100)

	# 检查插件是否可用
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin not available", "plugin_not_ready", 503)
		return

	# 获取日志条目
	var plugin = Engine.get_meta("gdapi_plugin")
	var entries: Array = plugin.get_log_since(since, limit)

	# 计算下一次获取的起始序列号
	var next_since: int = since
	if entries.size() > 0:
		next_since = entries[entries.size() - 1].seq

	# 返回日志条目和分页信息
	res.json({
		"ok": true,
		"entries": entries,
		"next_since": next_since,
	})
