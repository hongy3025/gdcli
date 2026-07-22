## runtime/debug/monitors — 读取标准 Performance 监控值

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const MONITOR_KEYS := ["FPS", "PROCESS_TIME", "PHYSICS_TIME", "OBJECT_COUNT", "OBJECT_NODE_COUNT", "OBJECT_RESOURCE_COUNT"]

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var values: Dictionary = {}
	for k in MONITOR_KEYS:
		values[k] = Performance.get_monitor(Performance[k])
	res.json({"monitors": values, "ok": true})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取标准 Performance 监控指标")
		.desc("返回 FPS、PROCESS_TIME、PHYSICS_TIME、OBJECT_COUNT、OBJECT_NODE_COUNT、OBJECT_RESOURCE_COUNT 的当前值。")
		.returns("结果", {
			"monitors": "Object, 每个键对应一个数值",
			"ok": "bool",
		})
	)
