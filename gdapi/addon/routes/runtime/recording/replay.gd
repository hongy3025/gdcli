@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/recording/replay", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Replay real runtime input")
		. mutates()
		. desc(
			(
				"Injects validated events in timestamp order with original relative spacing "
				+ "and at least one frame per event. Returns actual completed/cancelled/"
				+ "timed_out/failed state. Reset cancels pending replay and clears recording; "
				+ "export read items and pass events to replay after reset."
			)
		)
		. param(
			"events",
			"Array",
			false,
			"At most 1000 ordered {at_ms,route,data}; omitted uses current recording"
		)
		. param("timeout_ms", "int", false, "Operation deadline 1..25000 ms; default 5000")
		. example('{"events":[]}')
		. returns(
			"Replay completion",
			{
				"status": "String",
				"completed_events": "int",
				"total_events": "int",
				"elapsed_ms": "int",
				"changed": "bool",
				"undoable": "bool"
			}
		)
	)
