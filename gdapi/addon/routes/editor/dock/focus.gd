@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/dock/focus"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("dock/focus", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Focus a dock, script or filesystem target")
		. mutates()
		. param("name", "String", true, "Dock name")
		. param("path", "String", false, "Script or FileSystem target path")
		. param("line", "int", false, "One-based script line")
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
