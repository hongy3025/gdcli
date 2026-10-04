@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/settings/set"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("settings/set", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Set and persist an EditorSettings setting with disk read-back")
		. mutates()
		. param("name", "String", true, "Existing non-dangerous setting name")
		. param("value", "Variant", true, "Typed VariantCodec value matching existing setting")
		. example('{"name":"interface/editor/save_on_focus_loss","value":false}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
