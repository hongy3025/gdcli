@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var ps := ProjectSettings
	res.json({
		"ok": true,
		"name": ps.get_setting("application/config/name", ""),
		"main_scene": ps.get_setting("application/run/main_scene", ""),
		"godot_version": Engine.get_version_info().get("string", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"rendering_method": ps.get_setting("rendering/renderer/rendering_method", ""),
	})
