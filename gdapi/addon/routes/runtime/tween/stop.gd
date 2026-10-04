@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/tween/stop", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("真实运行期Tween stop")
		. mutates()
		. param("id", "String", true, "start返回的运行期tween ID", "")
		. example('{"id": "1"}')
		. returns(
			"result",
			{
				"state": "running/completed/cancelled/target_lost",
				"value": "当前真实属性值",
				"progress": "实际elapsed/duration"
			}
		)
	)
