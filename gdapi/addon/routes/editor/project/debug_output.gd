@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var since: int = req.get_body("since", 0)
	var limit: int = req.get_body("limit", 100)

	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin not available", "plugin_not_ready", 503)
		return

	var plugin = Engine.get_meta("gdapi_plugin")
	var entries: Array = plugin.get_log_since(since, limit)

	var next_since: int = since
	if entries.size() > 0:
		next_since = entries[entries.size() - 1].seq

	res.json({
		"ok": true,
		"entries": entries,
		"next_since": next_since,
	})
