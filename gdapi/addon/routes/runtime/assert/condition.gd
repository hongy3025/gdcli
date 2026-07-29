## runtime/assert/condition — 通过条件 grammar 等待节点属性满足

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/assert/condition", false)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("按条件 grammar 等待断言")
		.desc("使用 grammar:{op:and|or|not|eq|ne|lt|lte|gt|gte|contains, args|left, right}。操作对象可以是 literal 或 {node_path, property}。timeout_ms 后仍然不满足返回 409 conflict。")
		.param("condition", "Object", true, "条件语法节点", "")
		.param("timeout_ms", "int", false, "超时毫秒,默认 1000", "1000")
		.param("poll_ms", "int", false, "轮询间隔毫秒,默认 20", "20")
		.example("{\"condition\":{\"op\":\"gte\",\"left\":{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"property\":\"counter\"},\"right\":2},\"timeout_ms\":1000,\"poll_ms\":20}")
		.returns("结果", {
			"passed": "bool",
			"elapsed_ms": "int",
		})
	)
