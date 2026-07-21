## 添加节点路由处理器
##
## 提供向场景中添加新节点的 API 端点。
## 支持指定节点类型、名称、父节点路径和属性设置。
## 用于自动化场景构建和批量节点操作。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")

const ROUTE := "scene/add_node"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_type: String = req.get_body("node_type", "")
	var node_name: String = req.get_body("node_name", "")
	var parent_path: String = req.get_body("parent_node_path", "root")
	var properties: Dictionary = req.get_body("properties", {})
	var force: bool = req.get_body("force", false)

	# 验证必需参数
	if scene_path.is_empty():
		res.error("scene_path is required", ErrorCodes.MISSING_PARAM)
		return
	if node_type.is_empty():
		res.error("node_type is required", ErrorCodes.MISSING_PARAM)
		return
	if node_name.is_empty():
		res.error("node_name is required", ErrorCodes.MISSING_PARAM)
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

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to load scene: " + scene_path, ErrorCodes.GODOT_ERROR, 500)
		return

	var scene_root: Node = scene.instantiate()
	var parent: Node = scene_root
	if parent_path != "root":
		var relative_path := parent_path.replace("root/", "")
		parent = scene_root.get_node(relative_path)
		if not parent:
			AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "parent": parent_path}, false, ErrorCodes.NOT_FOUND)
			res.error("parent node not found: " + parent_path, ErrorCodes.NOT_FOUND, 404)
			return

	# 创建新节点
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type):
		AuditLog.record(ROUTE, "dangerous", {"node_type": node_type}, false, ErrorCodes.INVALID_PARAM)
		res.error("cannot instantiate node type: " + node_type, ErrorCodes.INVALID_PARAM, 400)
		return

	var new_node: Node = ClassDB.instantiate(node_type)
	new_node.name = node_name

	# 设置节点属性（使用 VariantCodec 解码）
	for prop in properties:
		var decoded := VariantCodec.decode(properties[prop])
		if not decoded.ok:
			AuditLog.record(ROUTE, "dangerous", {"property": prop}, false, ErrorCodes.INVALID_PARAM)
			res.error(decoded.error, ErrorCodes.INVALID_PARAM, 400, {"property": prop})
			return
		new_node.set(prop, decoded.value)

	parent.add_child(new_node)
	new_node.owner = scene_root

	# 打包并保存场景
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

	AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "node_name": node_name, "node_type": node_type}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"node_name": node_name,
		"node_type": node_type,
		"parent": parent_path,
	})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("向场景中添加新节点")
		.desc("在指定场景的父节点下创建新节点，支持通过 VariantCodec 设置属性（如 Vector2、Color 等），添加后设置 owner 并保存场景")
		.param("scene_path", "String", true, "场景路径")
		.param("node_type", "String", true, "节点类型名称（如 Sprite2D、Node2D 等）")
		.param("node_name", "String", true, "新节点名称")
		.param("force", "bool", true, "必须为 true 才执行")
		.param("parent_node_path", "String", false, "父节点路径，默认为 root", "root")
		.param("properties", "Dictionary", false, "要设置的节点属性字典，支持 VariantCodec 编码", {})
		.example("{\"scene_path\":\"res://test.tscn\",\"node_type\":\"Node2D\",\"node_name\":\"Child\",\"force\":true}")
		.returns("添加结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"saved": "bool, 是否已保存到磁盘",
			"undoable": "bool, 始终为 false",
			"node_name": "String, 新节点名称",
			"node_type": "String, 节点类型",
			"parent": "String, 父节点路径",
		})
	)
