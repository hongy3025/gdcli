## 加载精灵纹理路由处理器
##
## 提供为场景中的精灵节点加载纹理的 API 端点。
## 支持 Sprite2D、Sprite3D 和 TextureRect 类型的节点。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "scene/load_sprite"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_path: String = req.get_body("node_path", "")
	var texture_path: String = req.get_body("texture_path", "")
	var force: bool = req.get_body("force", false)

	if scene_path.is_empty():
		res.error("scene_path is required", ErrorCodes.MISSING_PARAM)
		return
	if node_path.is_empty():
		res.error("node_path is required", ErrorCodes.MISSING_PARAM)
		return
	if texture_path.is_empty():
		res.error("texture_path is required", ErrorCodes.MISSING_PARAM)
		return

	# 始终要求 force
	if not ErrorCodes.require_force(res, force, ROUTE):
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return

	# 校验路径
	var checked := PathGuard.validate(scene_path, "write")
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, checked.code)
		res.error(checked.error, checked.code, checked.status)
		return
	scene_path = checked.path

	checked = PathGuard.validate(texture_path, "read")
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"texture": texture_path}, false, checked.code)
		res.error(checked.error, checked.code, checked.status)
		return
	texture_path = checked.path

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to load scene: " + scene_path, ErrorCodes.GODOT_ERROR, 500)
		return

	var scene_root: Node = scene.instantiate()
	var sprite_path := node_path.replace("root/", "")
	var sprite_node = scene_root.get_node(sprite_path)
	if not sprite_node:
		AuditLog.record(ROUTE, "dangerous", {"node": node_path}, false, ErrorCodes.NOT_FOUND)
		res.error("node not found: " + node_path, ErrorCodes.NOT_FOUND, 404)
		return

	if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
		AuditLog.record(ROUTE, "dangerous", {"node": node_path, "class": sprite_node.get_class()}, false, ErrorCodes.INVALID_PARAM)
		res.error("node is not a sprite type: " + sprite_node.get_class(), ErrorCodes.INVALID_PARAM, 400)
		return

	var texture = load(texture_path)
	if not texture:
		AuditLog.record(ROUTE, "dangerous", {"texture": texture_path}, false, ErrorCodes.NOT_FOUND)
		res.error("failed to load texture: " + texture_path, ErrorCodes.NOT_FOUND, 404)
		return

	sprite_node.texture = texture

	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to pack scene: " + str(pack_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": pack_result})
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to save scene: " + str(save_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": save_result})
		return

	AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "node": node_path, "texture": texture_path}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"node": node_path,
		"texture": texture_path,
	})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("为精灵节点加载纹理")
		.desc("加载指定场景，找到目标精灵节点（Sprite2D/Sprite3D/TextureRect），设置新纹理并保存场景")
		.param("scene_path", "String", true, "场景路径")
		.param("node_path", "String", true, "精灵节点路径（如 root/Sprite2D）")
		.param("texture_path", "String", true, "纹理资源路径")
		.param("force", "bool", true, "必须为 true 才执行")
		.example("{\"scene_path\":\"res://test.tscn\",\"node_path\":\"root/Sprite2D\",\"texture_path\":\"res://icon.svg\",\"force\":true}")
		.returns("设置结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"saved": "bool, 是否已保存到磁盘",
			"undoable": "bool, 始终为 false",
			"node": "String, 精灵节点路径",
			"texture": "String, 纹理资源路径",
		})
	)
