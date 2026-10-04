@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/recording/read")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read recorded input events")
		. param("after_cursor", "int", false, "Exclusive event cursor; default 0")
		. param("limit", "int", false, "1..500; default 100")
		. example("{}")
		. returns(
			"Recording page",
			{
				"items": "Array of {cursor,at_ms,frame,route,data}",
				"next_cursor": "int",
				"status": "String",
				"recording_id": "String"
			}
		)
	)
