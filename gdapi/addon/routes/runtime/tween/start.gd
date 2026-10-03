@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/tween/start", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("真实运行期Tween start")
		. mutates()
		. param("node_path", "String", true, "专属运行节点路径", "")
		. param("property", "String", true, "运行allowlist内可插值属性", "")
		. param("from", "Object", false, "VariantCodec起点，默认当前值", "")
		. param("to", "Object", true, "VariantCodec目标值", "")
		. param("duration", "float", true, "正有限秒数，启动立即返回", "")
		. param("ease", "int", false, "Tween.EaseType枚举，默认IN_OUT", "")
		. param("trans", "int", false, "Tween.TransitionType枚举，默认LINEAR", "")
		. example(
			'{"node_path": "/root/RuntimeMain/ProbeTarget", "property": "position", '
			+ '"to": {"type": "Vector2", "value": [100, 0]}, "duration": 1.0}'
		)
		. returns(
			"result",
			{
				"state": "running/completed/cancelled/target_lost",
				"value": "当前真实属性值",
				"progress": "实际elapsed/duration"
			}
		)
	)
