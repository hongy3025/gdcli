@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/camera/get"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("camera/get", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read the real editor viewport camera")
		. param("dimension", "String", false, "2d or 3d (default 2d)")
		. param("index", "int", false, "3D viewport index 0..3")
		. example('{"dimension":"2d"}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
