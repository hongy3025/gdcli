@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/screenshot/viewport"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := await Controls.screenshot(req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Capture a real rendered editor viewport as PNG")
		. mutates()
		. param("path", "String", true, "Writable PNG path")
		. param("dimension", "String", false, "2d or 3d")
		. param("index", "int", false, "3D viewport index 0..3")
		. param("width", "int", false, "Output width 1..8192; requires height")
		. param("height", "int", false, "Output height 1..8192; requires width")
		. example('{"path":"res://viewport.png"}')
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
