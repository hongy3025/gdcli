@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")

	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		var plugin = Engine.get_meta("gdapi_plugin", null)
		if plugin:
			plugin.log_message("Started playing main scene", "info")
		res.json({"ok": true, "action": "play_main_scene"})
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, "not_found", 404)
		return

	EditorInterface.play_custom_scene(scene_path)

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Started playing scene: " + scene_path, "info")

	res.json({"ok": true, "action": "play_custom_scene", "scene": scene_path})
