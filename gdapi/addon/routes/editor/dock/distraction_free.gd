@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/dock/distraction_free"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("dock/distraction_free", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Set distraction-free mode")
		. mutates()
		. param("enabled", "bool", true, "Enable distraction-free mode")
		. example('{"enabled":true}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
