@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	var node_type: String = params.get("node_type", "")
	var node_name: String = params.get("node_name", "")
	var parent_path: String = params.get("parent_node_path", "root")
	var properties: Dictionary = params.get("properties", {})

	if scene_path.is_empty():
		return {"error": "scene_path is required", "code": "missing_param"}
	if node_type.is_empty():
		return {"error": "node_type is required", "code": "missing_param"}
	if node_name.is_empty():
		return {"error": "node_name is required", "code": "missing_param"}

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var scene := load(scene_path)
	if not scene:
		return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

	var scene_root := scene.instantiate()

	var parent: Node = scene_root
	if parent_path != "root":
		var relative_path := parent_path.replace("root/", "")
		parent = scene_root.get_node(relative_path)
		if not parent:
			return {"error": "parent node not found: " + parent_path, "code": "parent_not_found"}

	var new_node: Node = null
	if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
		new_node = ClassDB.instantiate(node_type)
	else:
		return {"error": "cannot instantiate node type: " + node_type, "code": "invalid_type"}

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
		return {"error": "failed to pack scene: " + str(pack_result), "code": "pack_failed"}

	var abs_path := ProjectSettings.globalize_path(scene_path)
	var save_result := ResourceSaver.save(packed, abs_path)
	if save_result != OK:
		return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

	return {
		"ok": true,
		"node_name": node_name,
		"node_type": node_type,
		"parent": parent_path,
	}
