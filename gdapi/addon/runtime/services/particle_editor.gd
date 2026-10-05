@tool
class_name GdApiParticleEditor
extends RefCounted

const Spatial := preload("res://addons/gdapi/runtime/services/scene_3d_editor.gd")
const NodePathResolver := preload("res://addons/gdapi/runtime/services/node_path_resolver.gd")
const TYPES := ["GPUParticles2D", "GPUParticles3D"]


static func create(payload: Dictionary) -> Dictionary:
	if not payload.get("type") is String or payload.type not in TYPES:
		return Spatial.error("type must be GPUParticles2D or GPUParticles3D")
	return Spatial.edit(_resolved(payload, "parent_path"), true, TYPES)


static func set_config(payload: Dictionary) -> Dictionary:
	return Spatial.edit(_resolved(payload, "node_path"), false, TYPES)


## node_path 同时接受场景根相对路径与 node/* 回传的绝对用户路径。
static func info(payload: Dictionary) -> Dictionary:
	if not payload.get("node_path", "") is String:
		return Spatial.error("node_path must be a String")
	if String(payload.node_path).is_empty():
		return Spatial.error("node_path is required", "missing_param")
	var found := NodePathResolver.resolve(payload.get("node_path", ""))
	if not found.ok:
		return Spatial.error(found.error, found.code)
	if found.node.get_class() not in TYPES:
		return Spatial.error("node must be GPUParticles2D or GPUParticles3D")
	return Spatial.inspect(found.node)


## 场景 3D 服务只接受绝对用户路径；这里把两种约定归一化后再委托。
## 空/缺失路径原样透传，保留既有的 missing/invalid 报错。
static func _resolved(payload: Dictionary, key: String) -> Dictionary:
	var value: Variant = payload.get(key, "")
	if not value is String or value.is_empty():
		return payload
	var found := NodePathResolver.resolve(value)
	if not found.ok:
		return payload
	var normalized := payload.duplicate()
	normalized[key] = found.path
	return normalized


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
