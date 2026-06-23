@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
	var _since: int = params.get("since", 0)
	var _limit: int = params.get("limit", 100)

	return {
		"ok": false,
		"error": "debug_output not implemented in this version",
		"code": "not_implemented",
		"hint": "This feature requires runtime buffer support. Will be implemented in a future version.",
	}
