@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/monitor/stop", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Stop property observation")
		. mutates()
		. desc(
			"Stops sampling immediately. Retains samples for reading "
			+ "until fixture reset or runtime generation exit."
		)
		. param("monitor_id", "String", true, "Subscription id")
		. returns(
			"Subscription",
			{"monitor_id": "String", "status": "String", "changed": "bool", "undoable": "bool"}
		)
	)
