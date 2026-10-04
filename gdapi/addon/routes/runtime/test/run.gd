@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/test/run", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Run runtime scene QA")
		. mutates()
		. desc(
			(
				"Runs a declarative scenario in the game process. A scene_path loads a real "
				+ "PackedScene in an isolated branch, cleaned after completion. "
				+ "Use $scene paths in steps. script_path accepts project-local JSON test scripts "
				+ "only; never eval or executable source. Controlled operations retain existing "
				+ "node method/property allowlists. Assertion failures and deadlines "
				+ "are preserved in a saved report."
			)
		)
		. param("scenario", "Dictionary", false, "{scene_path?, steps:[{op,data}]} up to 100 steps")
		. param(
			"script_path",
			"String",
			false,
			"Project-local .json scenario outside addons/.godot; alternative to scenario"
		)
		. param("timeout_ms", "int", false, "1..25000 ms total deadline")
		. example('{"scenario":{"steps":[]}}')
		. returns(
			"QA report",
			{
				"report_id": "String",
				"status": "passed|failed|timed_out|cancelled",
				"samples": "Array containing actual step outcomes and timings",
				"elapsed_ms": "int",
				"changed": "bool",
				"undoable": "bool"
			}
		)
	)
