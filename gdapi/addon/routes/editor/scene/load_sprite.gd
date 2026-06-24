## 加载精灵纹理路由处理器
##
## 提供为场景中的精灵节点加载纹理的 API 端点。
## 支持 Sprite2D、Sprite3D 和 TextureRect 类型的节点。
## 用于批量更新精灵纹理或自动化资源替换。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理精灵纹理加载请求
##
## 加载指定场景，找到目标精灵节点，设置新纹理并保存场景。
## @param req 请求对象，包含 scene_path、node_path 和 texture_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_path: String = req.get_body("node_path", "")
	var texture_path: String = req.get_body("texture_path", "")

	# 验证必需参数
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_path.is_empty():
		res.error("node_path is required", "missing_param")
		return
	if texture_path.is_empty():
		res.error("texture_path is required", "missing_param")
		return

	# 确保路径以 res:// 开头
	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not texture_path.begins_with("res://"):
		texture_path = "res://" + texture_path

	# 加载场景
	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	# 实例化场景并查找目标节点
	var scene_root: Node = scene.instantiate()

	var sprite_path := node_path.replace("root/", "")
	var sprite_node = scene_root.get_node(sprite_path)
	if not sprite_node:
		res.error("node not found: " + node_path, "node_not_found", 404)
		return

	# 验证节点类型是否为精灵
	if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
		res.error("node is not a sprite type: " + sprite_node.get_class(), "invalid_type", 400)
		return

	# 加载纹理资源
	var texture = load(texture_path)
	if not texture:
		res.error("failed to load texture: " + texture_path, "texture_not_found", 404)
		return

	# 设置精灵纹理
	sprite_node.texture = texture

	# 打包并保存场景
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

	# 返回成功响应
	res.json({
		"ok": true,
		"node": node_path,
		"texture": texture_path,
	})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("为精灵节点加载纹理") \
		.desc("加载指定场景，找到目标精灵节点（Sprite2D/Sprite3D/TextureRect），设置新纹理并保存场景；用于批量更新精灵纹理或自动化资源替换") \
		.param("scene_path", "String", true, "场景路径，可省略 res:// 前缀") \
		.param("node_path", "String", true, "精灵节点路径（如 root/Sprite2D）") \
		.param("texture_path", "String", true, "纹理资源路径，可省略 res:// 前缀") \
		.returns("设置结果", {
			"ok": "bool",
			"node": "String, 精灵节点路径",
			"texture": "String, 纹理资源路径",
		})
