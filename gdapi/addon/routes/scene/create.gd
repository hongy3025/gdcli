## 创建场景路由处理器
##
## 提供创建新 Godot 场景文件的 API 端点。
## 支持指定根节点类型，自动创建目录并保存场景。
## 创建后会自动重新加载场景到编辑器中。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理场景创建请求
##
## 创建指定类型的根节点，打包为场景并保存到指定路径。
## @param req 请求对象，包含 scene_path 和可选的 root_node_type
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return

	# 默认根节点类型为 Node2D
	var root_type: String = req.get_body("root_node_type", "Node2D")

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# 创建根节点
	var root_node: Node = null
	if ClassDB.class_exists(root_type) and ClassDB.can_instantiate(root_type):
		root_node = ClassDB.instantiate(root_type)
	else:
		res.error("cannot instantiate node type: " + root_type, "invalid_type", 400)
		return

	# 设置根节点属性
	root_node.name = "root"
	root_node.owner = root_node

	# 创建目标目录（如果不存在）
	var dir_path := scene_path.get_base_dir()
	if dir_path != "res://":
		var abs_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	# 打包场景
	var packed := PackedScene.new()
	var pack_result := packed.pack(root_node)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	# 保存场景文件
	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	# 重新加载场景到编辑器
	EditorInterface.reload_scene_from_path(scene_path)

	req.log_info("Created scene: " + scene_path)

	# 返回成功响应
	res.json({
		"ok": true,
		"path": scene_path,
		"root_type": root_type,
	})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("创建新 Godot 场景文件")
		.desc("创建指定类型的根节点，打包为场景并保存到指定路径；自动创建不存在的目录；创建后自动重新加载场景到编辑器中")
		.param("scene_path", "String", true, "新场景的保存路径，可省略 res:// 前缀")
		.param("root_node_type", "String", false, "根节点类型名称，默认为 Node2D", "Node2D")
		.returns("创建结果", {
			"ok": "bool",
			"path": "String, 场景保存路径",
			"root_type": "String, 根节点类型",
		})
	)
