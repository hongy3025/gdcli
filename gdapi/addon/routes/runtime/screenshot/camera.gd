## runtime/screenshot/camera — 按 camera 节点的视口截屏

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_capture_ops.gd")
	var result: Dictionary = await ops.camera(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "camera capture failed")), String(result.get("code", "godot_error")), 500)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("截 Camera2D/3D 的视口")
		.desc("node_path 必须指向一个 Camera2D 或 Camera3D,其它类型返回 invalid_param。")
		.param("node_path", "String", true, "Camera 节点绝对路径", "")
		.example("{\"node_path\":\"/root/RuntimeMain/MainCamera\"}")
		.returns("截图结果", {
			"mime": "String, image/png",
			"width": "int",
			"height": "int",
			"sha256": "String",
			"data_base64": "String",
			"camera": "String, 相机路径",
		})
	)
