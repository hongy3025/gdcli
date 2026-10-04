@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/settings/get"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("settings/get", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read a real EditorSettings setting")
		. param("name", "String", true, "Setting name")
		. example('{"name":"interface/editor/save_on_focus_loss"}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
