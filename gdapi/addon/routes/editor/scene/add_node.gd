@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_type: String = req.get_body("node_type", "")
	var node_name: String = req.get_body("node_name", "")
	var parent_path: String = req.get_body("parent_node_path", "root")
	var properties: Dictionary = req.get_body("properties", {})

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_type.is_empty():
		res.error("node_type is required", "missing_param")
		return
	if node_name.is_empty():
		res.error("node_name is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

	var parent: Node = scene_root
	if parent_path != "root":
		var relative_path := parent_path.replace("root/", "")
		parent = scene_root.get_node(relative_path)
		if not parent:
			res.error("parent node not found: " + parent_path, "parent_not_found", 404)
			return

	var new_node: Node = null
	if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
		new_node = ClassDB.instantiate(node_type)
	else:
		res.error("cannot instantiate node type: " + node_type, "invalid_type", 400)
		return

	new_node.name = node_name

	for prop in properties:
		var value = properties[prop]
		if typeof(value) == TYPE_STRING and value.begins_with("res://"):
			value = load(value)
		new_node.set(prop, value)

	parent.add_child(new_node)
	new_node.owner = scene_root

	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Added node " + node_name + " (" + node_type + ") to " + scene_path, "info")

	res.json({
		"ok": true,
		"node_name": node_name,
		"node_type": node_type,
		"parent": parent_path,
	})
