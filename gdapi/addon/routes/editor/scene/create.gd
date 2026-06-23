@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		return {"error": "scene_path is required", "code": "missing_param"}

	var root_type: String = params.get("root_node_type", "Node2D")

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# 创建根节点
	var root_node: Node = null
	if ClassDB.class_exists(root_type) and ClassDB.can_instantiate(root_type):
		root_node = ClassDB.instantiate(root_type)
	else:
		return {"error": "cannot instantiate node type: " + root_type, "code": "invalid_type"}

	root_node.name = "root"
	root_node.owner = root_node

	# 确保目录存在
	var dir_path := scene_path.get_base_dir()
	if dir_path != "res://":
		var abs_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	# 打包并保存场景
	var packed := PackedScene.new()
	var pack_result := packed.pack(root_node)
	if pack_result != OK:
		return {"error": "failed to pack scene: " + str(pack_result), "code": "pack_failed"}

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

	EditorInterface.reload_scene_from_path(scene_path)

	# 记录日志
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Created scene: " + scene_path, "info")

	return {
		"ok": true,
		"path": scene_path,
		"root_type": root_type,
	}
