@tool
class_name GdApiParticleEditor
extends RefCounted

const Spatial := preload("res://addons/gdapi/runtime/services/scene_3d_editor.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const TYPES := ["GPUParticles2D", "GPUParticles3D"]


static func create(payload: Dictionary) -> Dictionary:
	if not payload.get("type") is String or payload.type not in TYPES:
		return Spatial.error("type must be GPUParticles2D or GPUParticles3D")
	return Spatial.edit(payload, true, TYPES)


static func set_config(payload: Dictionary) -> Dictionary:
	return Spatial.edit(payload, false, TYPES)


static func info(payload: Dictionary) -> Dictionary:
	if not payload.get("node_path", "") is String:
		return Spatial.error("node_path must be a String")
	var found := NodeEditor.find(payload.get("node_path", ""))
	if not found.ok:
		return found
	if found.node.get_class() not in TYPES:
		return Spatial.error("node must be GPUParticles2D or GPUParticles3D")
	return Spatial.inspect(found.node)


# Called only inside the running game by runtime_probe.
static func runtime_info(payload: Dictionary) -> Dictionary:
	var path: Variant = payload.get("node_path", "")
	if not path is String or not path.begins_with("/root/") or path.contains(".."):
		return Spatial.error("node_path must be an absolute /root/ path")
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return Spatial.error("runtime SceneTree is unavailable", "not_found")
	var node := tree.root.get_node_or_null(NodePath(path))
	if node == null:
		return Spatial.error("particle node not found: " + path, "not_found")
	if node.get_class() not in TYPES:
		return Spatial.error("node must be GPUParticles2D or GPUParticles3D")
	var observed := Spatial.inspect(node)
	observed.emitting = node.get("emitting")
	observed.amount = node.get("amount")
	observed.lifetime = node.get("lifetime")
	observed.one_shot = node.get("one_shot")
	observed.speed_scale = node.get("speed_scale")
	observed.process_material = Spatial.encode_value(node.get("process_material"))
	observed.inside_tree = node.is_inside_tree()
	observed.visible = node.call("is_visible_in_tree")
	observed.process_frame = Engine.get_process_frames()
	return {"ok": true, "result": observed}
