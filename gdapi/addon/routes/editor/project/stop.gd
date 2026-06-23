@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return {"ok": true, "action": "stop", "message": "not playing"}

	EditorInterface.stop_playing_scene()

	# 记录日志
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Stopped playing scene", "info")

	return {"ok": true, "action": "stop"}
