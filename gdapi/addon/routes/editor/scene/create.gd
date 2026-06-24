@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return

	var root_type: String = req.get_body("root_node_type", "Node2D")

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var root_node: Node = null
	if ClassDB.class_exists(root_type) and ClassDB.can_instantiate(root_type):
		root_node = ClassDB.instantiate(root_type)
	else:
		res.error("cannot instantiate node type: " + root_type, "invalid_type", 400)
		return

	root_node.name = "root"
	root_node.owner = root_node

	var dir_path := scene_path.get_base_dir()
	if dir_path != "res://":
		var abs_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var packed := PackedScene.new()
	var pack_result := packed.pack(root_node)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	EditorInterface.reload_scene_from_path(scene_path)

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Created scene: " + scene_path, "info")

	res.json({
		"ok": true,
		"path": scene_path,
		"root_type": root_type,
	})
