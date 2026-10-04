@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/recording/cancel", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Cancel active input replay")
		. mutates()
		. desc(
			(
				"Cancellation is observed on the next process frame; "
				+ "the pending replay request completes once with its actual injected event count."
			)
		)
		. returns("Cancellation", {"replay": "Dictionary", "changed": "bool", "undoable": "bool"})
	)
