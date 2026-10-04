@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/monitor/read")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read typed property changes")
		. param("monitor_id", "String", true, "Subscription id")
		. param("after_cursor", "int", false, "Exclusive cursor; default 0")
		. param("limit", "int", false, "1..500; default 100")
		. example('{"monitor_id":"1"}')
		. returns(
			"Change page",
			{
				"items": "Array of {cursor,at_ms,frame,value|error}",
				"next_cursor": "int",
				"oldest_cursor": "int",
				"cursor": "int",
				"status": "running|stopped|target_missing"
			}
		)
	)
