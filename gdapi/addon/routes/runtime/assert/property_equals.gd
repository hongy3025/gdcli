## runtime/assert/property_equals — 等节点属性等于期望值

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = await ops.assert_property_equals(payload)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "assert/property_equals failed")), String(result.get("code", "conflict")), 409)
		return
	var inner := result.get("result", {})
	if typeof(inner) != TYPE_DICTIONARY:
		inner = {"value": inner}
	inner["ok"] = true
	res.json(inner)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("等待节点属性等于期望值")
		.desc("每 10ms 检查一次,直到属性 == value,或 timeout_ms 后失败。")
		.param("node_path", "String", true, "节点路径", "")
		.param("property", "String", true, "属性名", "")
		.param("value", "Variant", true, "期望值", "")
		.param("timeout_ms", "int", false, "超时毫秒", "1000")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"property\":\"counter\",\"value\":7,\"timeout_ms\":1000}")
		.returns("结果", {"passed": "bool", "value": "Variant"})
	)
