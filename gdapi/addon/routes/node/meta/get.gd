@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "node/meta/get"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := NodeEditor.metadata(
		str(req.get_body("node_path", "")),
		str(req.get_body("key", "")),
		"get",
		req.get_body("value")
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Read typed metadata")
		. param("node_path", "String", true, "Edited-scene node path")
		. param(
			"key",
			"String",
			true,
			"Metadata identifier; internal and gdapi_ mutation keys protected"
		)
		. returns(
			"Operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
