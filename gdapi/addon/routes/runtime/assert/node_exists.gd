## runtime/assert/node_exists — 等指定路径的节点出现

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = await ops.assert_node_exists(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "assert/node_exists failed")), String(result.get("code", "conflict")), 409)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("等待节点出现在指定路径")
		.desc("直到 SceneTree 中出现 node_path,或 timeout_ms 后失败。")
		.param("node_path", "String", true, "绝对路径", "")
		.param("timeout_ms", "int", false, "超时毫秒,默认 1000", "1000")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"timeout_ms\":500}")
		.returns("结果", {"passed": "bool", "node": "String"})
	)
