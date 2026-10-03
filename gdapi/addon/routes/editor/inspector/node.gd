@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/inspector/node"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("inspector/node", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Inspect an edited-scene node")
		. mutates()
		. param("node_path", "String", true, "Absolute edited-scene node path")
		. param("property", "String", false, "Property to focus")
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
