@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/test/stress", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Stress controlled runtime operations")
		. mutates()
		. desc(
			(
				"Actually executes scenario iterations in concurrent coroutine batches, "
				+ "with independent loaded scene branches, one shared absolute deadline, "
				+ "actual step timing/failure samples, and complete worker cleanup before returning."
			)
		)
		. param("scenario", "Dictionary", false, "Same controlled scenario as runtime/test/run")
		. param("script_path", "String", false, "Project-local declarative JSON test script")
		. param("iterations", "int", false, "1..100; default 10")
		. param("concurrency", "int", false, "1..8; default 2")
		. param("timeout_ms", "int", false, "1..25000 ms")
		. example('{"scenario":{"steps":[]}}')
		. returns(
			"Stress report",
			{
				"report_id": "String",
				"status": "String",
				"completed_iterations": "int",
				"passed_iterations": "int",
				"failed_iterations": "int",
				"samples": "Array",
				"elapsed_ms": "int",
				"changed": "bool",
				"undoable": "bool"
			}
		)
	)
