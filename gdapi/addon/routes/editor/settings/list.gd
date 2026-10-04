@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/settings/list"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("settings/list", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("List real EditorSettings values")
		. param("prefix", "String", false, "Setting-name prefix")
		. example('{"prefix":"interface/editor/"}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
