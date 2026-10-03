@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/recording/start", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Record real runtime input")
		. mutates()
		. desc(
			"Captures supported InputEvents in the running game, including broker-controlled input. "
			+ "Stops automatically at max_events."
		)
		. param("max_events", "int", false, "1..1000; default 100")
		. returns(
			"Recording",
			{"recording_id": "String", "status": "String", "changed": "bool", "undoable": "bool"}
		)
	)
