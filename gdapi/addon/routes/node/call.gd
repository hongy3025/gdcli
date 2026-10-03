@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "node/call"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := NodeEditor.call_method(req.body)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Call an allowlisted editor node method with audited failures")
		. mutates()
		. param("node_path", "String", true, "Edited-scene node path")
		. param(
			"method",
			"String",
			true,
			"Safe native method, or @tool method explicitly declared in gdapi_callable_methods"
		)
		. param("args", "Array", false, "Typed VariantCodec arguments matching method signature")
		. returns(
			"Operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
