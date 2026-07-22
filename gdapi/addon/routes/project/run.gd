## 运行项目路由处理器
##
## 提供运行 Godot 场景的 API 端点。
## 支持运行主场景或指定路径的自定义场景。
## 用于自动化测试和快速预览场景。
## M3: 启动前调用 runtime broker.begin_connect()，
##      让公共状态 API 能反映 connecting → connected 的过渡。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")

## 处理运行场景请求
##
## 根据请求参数运行主场景或指定路径的场景。
## 如果未提供 scene_path，则运行主场景；否则运行指定路径的场景。
## @param req 请求对象，包含可选的 scene_path
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var broker: Variant = RuntimeBroker.instance()
	if broker != null:
		broker.begin_connect()

	var scene_path: String = req.get_body("scene_path", "")

	# 如果未指定场景路径，运行主场景
	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		req.log_info("Started playing main scene")
		res.json({
			"ok": true,
			"action": "play_main_scene",
			"runtime_state": _runtime_state_label(broker),
		})
		return

	# 使用 PathGuard 校验路径
	var checked := PathGuard.validate(scene_path, "read")
	if not checked.ok:
		res.error(checked.error, checked.code, checked.status)
		return
	scene_path = checked.path

	# 检查场景文件是否存在
	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, "not_found", 404)
		return

	# 运行指定场景
	EditorInterface.play_custom_scene(scene_path)

	req.log_info("Started playing scene: " + scene_path)

	# 返回成功响应
	res.json({
		"ok": true,
		"action": "play_custom_scene",
		"scene": scene_path,
		"runtime_state": _runtime_state_label(broker),
	})

## 把 broker 当前 state 转字符串,便于外部调试
##
## @param broker 可能为 null;null 表示 broker 未注册
## @return state 字符串
func _runtime_state_label(broker: Variant) -> String:
	if broker == null:
		return "stopped"
	var status: Dictionary = broker.status()
	return String(status.get("state", "stopped"))

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("运行 Godot 场景")
		.desc("不带 scene_path 时运行主场景；带 scene_path 时运行指定路径的自定义场景；用于自动化测试和快速预览。M3 同时把 runtime broker 切换到 connecting,等待 EditorDebuggerPlugin 的 hello")
		.param("scene_path", "String", false, "要运行的场景路径,留空则运行主场景", "")
		.example("{\"scene_path\":\"res://test.tscn\"}")
		.returns("运行结果", {
			"ok": "bool",
			"action": "String, play_main_scene 或 play_custom_scene",
			"scene": "String, 仅自定义场景模式存在，运行的场景路径",
			"runtime_state": "String, stopped|connecting|connected",
		})
	)
