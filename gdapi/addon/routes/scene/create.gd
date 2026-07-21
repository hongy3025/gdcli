## 创建场景路由处理器
##
## 提供创建新 Godot 场景文件的 API 端点。
## 支持指定根节点类型，自动创建目录并保存场景。
## 创建后会自动重新加载场景到编辑器中。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "scene/create"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	if scene_path.is_empty():
		res.error("scene_path is required", ErrorCodes.MISSING_PARAM)
		return

	var root_type: String = req.get_body("root_node_type", "Node2D")
	var force: bool = req.get_body("force", false)

	# 校验路径
	var checked := PathGuard.validate(scene_path, "write")
	if not checked.ok:
		res.error(checked.error, checked.code, checked.status)
		return
	scene_path = checked.path

	# 目标已存在时要求 force
	if FileAccess.file_exists(ProjectSettings.globalize_path(scene_path)):
		if not ErrorCodes.require_force(res, force, ROUTE):
			AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
			return

	# 创建根节点
	if not ClassDB.class_exists(root_type) or not ClassDB.can_instantiate(root_type):
		res.error("cannot instantiate node type: " + root_type, ErrorCodes.INVALID_PARAM, 400)
		return

	var root_node: Node = ClassDB.instantiate(root_type)
	root_node.name = "root"
	root_node.owner = root_node

	# 创建目标目录
	var dir_path := scene_path.get_base_dir()
	if dir_path != "res://":
		var abs_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	# 打包场景
	var packed := PackedScene.new()
	var pack_result := packed.pack(root_node)
	if pack_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to pack scene: " + str(pack_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": pack_result})
		return

	# 保存场景文件
	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to save scene: " + str(save_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": save_result})
		return

	EditorInterface.reload_scene_from_path(scene_path)

	AuditLog.record(ROUTE, "dangerous", {"target": scene_path, "root_type": root_type}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": scene_path,
		"root_type": root_type,
	})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("创建新 Godot 场景文件")
		.desc("创建指定类型的根节点，打包为场景并保存到指定路径；自动创建不存在的目录；创建后自动重新加载场景到编辑器中")
		.param("scene_path", "String", true, "新场景的保存路径")
		.param("root_node_type", "String", false, "根节点类型名称，默认为 Node2D", "Node2D")
		.param("force", "bool", false, "目标已存在时需为 true")
		.example("{\"scene_path\":\"res://new_scene.tscn\",\"root_node_type\":\"Node2D\",\"force\":false}")
		.returns("创建结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"saved": "bool, 是否已保存到磁盘",
			"undoable": "bool, 始终为 false",
			"path": "String, 场景保存路径",
			"root_type": "String, 根节点类型",
		})
	)
