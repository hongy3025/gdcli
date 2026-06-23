@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")

	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		# 记录日志
		var plugin = Engine.get_meta("gdapi_plugin", null)
		if plugin:
			plugin.log_message("Started playing main scene", "info")
		return {"ok": true, "action": "play_main_scene"}

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		return {"error": "scene not found: " + scene_path, "code": "not_found"}

	EditorInterface.play_custom_scene(scene_path)

	# 记录日志
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Started playing scene: " + scene_path, "info")

	return {"ok": true, "action": "play_custom_scene", "scene": scene_path}
