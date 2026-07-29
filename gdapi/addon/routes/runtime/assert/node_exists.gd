## runtime/assert/node_exists — 等指定路径的节点出现

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/assert/node_exists", false)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("等待节点出现在指定路径")
		. desc("直到 SceneTree 中出现 node_path,或 timeout_ms 后失败。")
		. param("node_path", "String", true, "绝对路径", "")
		. param("timeout_ms", "int", false, "超时毫秒,默认 1000", "1000")
		. example('{"node_path":"/root/RuntimeMain/ProbeTarget","timeout_ms":500}')
		. returns("结果", {"passed": "bool", "node": "String"})
	)
