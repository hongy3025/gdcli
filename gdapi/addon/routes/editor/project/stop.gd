@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not EditorInterface.is_playing_scene():
		res.json({"ok": true, "action": "stop", "message": "not playing"})
		return

	EditorInterface.stop_playing_scene()

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Stopped playing scene", "info")

	res.json({"ok": true, "action": "stop"})
