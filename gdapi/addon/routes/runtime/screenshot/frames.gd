## runtime/screenshot/frames — 按时序截多帧
##
## 最多 60 帧,累计不能超过 4 MiB 编码后大小。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_capture_ops.gd")
	var result: Dictionary = await ops.frames(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "frames capture failed")), String(result.get("code", "godot_error")), 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("按间隔连续截多帧")
		.desc("count 默认 2,最大 60;interval_ms 默认 16。可选 camera_path 指向 Camera2D/3D 节点。")
		.param("count", "int", false, "帧数 1..60,默认 2", "2")
		.param("interval_ms", "int", false, "帧间间隔毫秒 1..1000", "16")
		.param("camera_path", "String", false, "可选 Camera 节点路径", "")
		.example("{\"count\":3,\"interval_ms\":16}")
		.returns("帧集合", {
			"frames": "Array, 每项 {index, width, height, sha256, data_base64}",
			"count": "int, 实际返回的帧数",
		})
	)
