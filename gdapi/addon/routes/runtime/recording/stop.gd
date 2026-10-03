@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/recording/stop", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Stop input recording")
		. mutates()
		. desc(
			"Stops capture while retaining bounded events for read/replay until reset or the next start."
		)
		. returns(
			"Recording",
			{
				"recording_id": "String",
				"status": "String",
				"count": "int",
				"changed": "bool",
				"undoable": "bool"
			}
		)
	)
