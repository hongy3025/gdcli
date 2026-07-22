## runtime/node/info — 查询运行期节点的元信息

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var ops := load("res://addons/gdapi/runtime/runtime_node_ops.gd")
	var result: Dictionary = ops.info(payload)
	if not bool(result.get("ok", false)):
		var code: String = String(result.get("code", "godot_error"))
		res.error(String(result.get("error", "runtime/node/info failed")), code, 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询运行期节点的类型和公开属性")
		.desc("node_path 必须以 /root/ 开头绝对路径。返回类型名、脚本路径和公开属性列表。")
		.param("node_path", "String", true, "节点路径,如 /root/RuntimeMain/ProbeTarget", "")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\"}")
		.returns("节点信息", {
			"node_path": "String",
			"type": "String",
			"script": "String",
			"properties": "Array, 公开属性名",
		})
	)
