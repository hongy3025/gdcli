## runtime/log/clear — 清空运行期日志 ring buffer

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var probe: Variant = _lookup_probe()
	if probe == null:
		res.error("runtime_probe is not registered", "not_found", 404)
		return
	var ring: Variant = probe.ring_buffer()
	var info: Dictionary = ring.clear()
	res.json(info)

func _lookup_probe() -> Variant:
	var root := Engine.get_main_loop() as SceneTree
	if root == null:
		return null
	return root.root.get_node_or_null("GdApiRuntimeProbe")

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("清空运行期日志 ring buffer")
		.desc("返回 cleared(已清理条目数)和 next_cursor=0。")
		.returns("清理结果", {
			"cleared": "int",
			"next_cursor": "int",
		})
	)
