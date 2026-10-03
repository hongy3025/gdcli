@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/test/report")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read saved runtime QA results")
		. desc(
			"Returns actual run/stress results, including pending state if queried during execution. "
			+ "Last 100 reports retained until reset or runtime generation exit."
		)
		. param("report_id", "String", true, "Id returned by run/stress")
		. returns(
			"QA report",
			{
				"report_id": "String",
				"status": "String",
				"samples": "Array",
				"elapsed_ms": "int",
				"completed_iterations": "int"
			}
		)
	)
