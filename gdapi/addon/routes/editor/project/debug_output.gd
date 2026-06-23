@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var since: int = params.get("since", 0)
	var limit: int = params.get("limit", 100)

	# 从 Engine meta 获取 plugin 实例
	if not Engine.has_meta("gdapi_plugin"):
		return {
			"ok": false,
			"error": "gdapi plugin not available",
			"code": "plugin_not_ready",
		}

	var plugin = Engine.get_meta("gdapi_plugin")
	var entries: Array = plugin.get_log_since(since, limit)

	var next_since: int = since
	if entries.size() > 0:
		next_since = entries[entries.size() - 1].seq

	return {
		"ok": true,
		"entries": entries,
		"next_since": next_since,
	}
