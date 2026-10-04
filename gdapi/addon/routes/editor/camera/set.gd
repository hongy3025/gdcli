@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Controls := preload("res://addons/gdapi/runtime/services/editor_controls.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "editor/camera/set"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Controls.dispatch("camera/set", req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Override the real viewport camera at render time")
		. mutates()
		. param("dimension", "String", false, "2d or 3d")
		. param("index", "int", false, "3D viewport index 0..3")
		. param(
			"transform",
			"Variant",
			false,
			"Transform2D canvas transform or Transform3D camera global transform"
		)
		. param("fov", "float", false, "3D field of view, 1..179")
		. param(
			"release", "bool", false, "Release override and restore native interactive navigation"
		)
		. example(
			'{"dimension":"2d","transform":{"type":"Transform2D","value":[[2,0],[0,2],[120,90]]}}'
		)
		. returns(
			"Editor operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
