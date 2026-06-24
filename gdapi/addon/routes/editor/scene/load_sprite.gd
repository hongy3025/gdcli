@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_path: String = req.get_body("node_path", "")
	var texture_path: String = req.get_body("texture_path", "")

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_path.is_empty():
		res.error("node_path is required", "missing_param")
		return
	if texture_path.is_empty():
		res.error("texture_path is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not texture_path.begins_with("res://"):
		texture_path = "res://" + texture_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

	var sprite_path := node_path.replace("root/", "")
	var sprite_node = scene_root.get_node(sprite_path)
	if not sprite_node:
		res.error("node not found: " + node_path, "node_not_found", 404)
		return

	if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
		res.error("node is not a sprite type: " + sprite_node.get_class(), "invalid_type", 400)
		return

	var texture = load(texture_path)
	if not texture:
		res.error("failed to load texture: " + texture_path, "texture_not_found", 404)
		return

	sprite_node.texture = texture

	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var abs_path := ProjectSettings.globalize_path(scene_path)
	var save_result := ResourceSaver.save(packed, abs_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	res.json({
		"ok": true,
		"node": node_path,
		"texture": texture_path,
	})
