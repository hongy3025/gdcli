## 添加节点路由处理器
##
## 提供向场景中添加新节点的 API 端点。
## 支持指定节点类型、名称、父节点路径和属性设置。
## 用于自动化场景构建和批量节点操作。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理节点添加请求
##
## 在指定场景的父节点下创建新节点，设置属性后保存场景。
## @param req 请求对象，包含 scene_path、node_type、node_name、parent_node_path 和 properties
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_type: String = req.get_body("node_type", "")
	var node_name: String = req.get_body("node_name", "")
	var parent_path: String = req.get_body("parent_node_path", "root")
	var properties: Dictionary = req.get_body("properties", {})

	# 验证必需参数
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_type.is_empty():
		res.error("node_type is required", "missing_param")
		return
	if node_name.is_empty():
		res.error("node_name is required", "missing_param")
		return

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	# 实例化场景并查找父节点
	var scene_root: Node = scene.instantiate()

	var parent: Node = scene_root
	if parent_path != "root":
		var relative_path := parent_path.replace("root/", "")
		parent = scene_root.get_node(relative_path)
		if not parent:
			res.error("parent node not found: " + parent_path, "parent_not_found", 404)
			return

	# 创建新节点
	var new_node: Node = null
	if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
		new_node = ClassDB.instantiate(node_type)
	else:
		res.error("cannot instantiate node type: " + node_type, "invalid_type", 400)
		return

	# 设置节点名称
	new_node.name = node_name

	# 设置节点属性，支持资源路径自动加载
	for prop in properties:
		var value = properties[prop]
		if typeof(value) == TYPE_STRING and value.begins_with("res://"):
			value = load(value)
		new_node.set(prop, value)

	# 添加节点到父节点并设置所有者
	parent.add_child(new_node)
	new_node.owner = scene_root

	# 打包并保存场景
	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	req.log_info("Added node " + node_name + " (" + node_type + ") to " + scene_path)

	# 返回成功响应
	res.json({
		"ok": true,
		"node_name": node_name,
		"node_type": node_type,
		"parent": parent_path,
	})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("向场景中添加新节点")
		.desc("在指定场景的父节点下创建新节点，支持设置节点属性（支持 res:// 资源路径自动加载），添加后设置 owner 并保存场景；用于自动化场景构建和批量节点操作")
		.param("scene_path", "String", true, "场景路径，可省略 res:// 前缀")
		.param("node_type", "String", true, "节点类型名称（如 Sprite2D、Node2D、CharacterBody3D 等）")
		.param("node_name", "String", true, "新节点名称")
		.param("parent_node_path", "String", false, "父节点路径，默认为 root", "root")
		.param("properties", "Dictionary", false, "要设置的节点属性字典，支持 res:// 路径自动加载资源", {})
		.returns("添加结果", {
			"ok": "bool",
			"node_name": "String, 新节点名称",
			"node_type": "String, 节点类型",
			"parent": "String, 父节点路径",
		})
	)
