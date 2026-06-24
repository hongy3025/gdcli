@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var file_path: String = req.get_body("file_path", "")
	if file_path.is_empty():
		res.error("file_path is required", "missing_param")
		return

	if not file_path.begins_with("res://"):
		file_path = "res://" + file_path

	var abs_path := ProjectSettings.globalize_path(file_path)
	if not FileAccess.file_exists(abs_path):
		res.error("file not found: " + file_path, "not_found", 404)
		return

	var uid_path := file_path + ".uid"
	var uid_content := ""
	var uid_exists := false

	if FileAccess.file_exists(uid_path):
		var f := FileAccess.open(uid_path, FileAccess.READ)
		if f:
			uid_content = f.get_as_text().strip_edges()
			f.close()
			uid_exists = true

	res.json({
		"ok": true,
		"file": file_path,
		"absolute_path": abs_path,
		"uid": uid_content,
		"uid_exists": uid_exists,
	})
