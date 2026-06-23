@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	var node_path: String = params.get("node_path", "")
	var texture_path: String = params.get("texture_path", "")

	if scene_path.is_empty():
		return {"error": "scene_path is required", "code": "missing_param"}
	if node_path.is_empty():
		return {"error": "node_path is required", "code": "missing_param"}
	if texture_path.is_empty():
		return {"error": "texture_path is required", "code": "missing_param"}

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not texture_path.begins_with("res://"):
		texture_path = "res://" + texture_path

	var scene := load(scene_path)
	if not scene:
		return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

	var scene_root := scene.instantiate()

	var sprite_path := node_path.replace("root/", "")
	var sprite_node = scene_root.get_node(sprite_path)
	if not sprite_node:
		return {"error": "node not found: " + node_path, "code": "node_not_found"}

	if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
		return {"error": "node is not a sprite type: " + sprite_node.get_class(), "code": "invalid_type"}

	var texture = load(texture_path)
	if not texture:
		return {"error": "failed to load texture: " + texture_path, "code": "texture_not_found"}

	sprite_node.texture = texture

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
		"node": node_path,
		"texture": texture_path,
	}
