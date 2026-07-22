## runtime/log/read — 增量读取运行期日志 ring buffer

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var probe: Variant = _lookup_probe()
	if probe == null:
		res.error("runtime_probe is not registered", "not_found", 404)
		return
	var ring: Variant = probe.ring_buffer()
	var after_cursor: int = int(payload.get("after_cursor", 0))
	var limit: int = int(payload.get("limit", 100))
	var page: Dictionary = ring.read(after_cursor, limit)
	res.json(page)

func _lookup_probe() -> Variant:
	var root := Engine.get_main_loop() as SceneTree
	if root == null:
		return null
	return root.root.get_node_or_null("GdApiRuntimeProbe")

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("增量读取运行期日志")
		.desc("after_cursor 表示上次读取之后的下一个 cursor;limit 默认 100,最大 500。每次最多返回 dropped 条目丢弃提示。")
		.param("after_cursor", "int", false, "上次读取之后的 cursor,默认 0 从头开始", "0")
		.param("limit", "int", false, "本次最多返回的条目数", "100")
		.example("{\"after_cursor\":0,\"limit\":50}")
		.returns("读取结果", {
			"items": "Array, 每项 {cursor,level,message,details,ts}",
			"next_cursor": "int, 下一次读取的起点",
			"dropped": "int, 已丢弃的条目数",
		})
	)
