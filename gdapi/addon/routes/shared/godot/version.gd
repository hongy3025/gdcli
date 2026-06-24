@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var info := Engine.get_version_info()
	res.json({
		"ok": true,
		"version": info.get("string", ""),
		"major": info.get("major", 0),
		"minor": info.get("minor", 0),
		"patch": info.get("patch", 0),
		"status": info.get("status", ""),
		"build": info.get("build", ""),
	})
