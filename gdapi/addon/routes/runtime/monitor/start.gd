@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/monitor/start", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Monitor a property across frames")
		. mutates()
		. desc(
			(
				"Samples typed VariantCodec values in runtime _process and retains "
				+ "only changes plus the initial value. At most 32 subscriptions "
				+ "and 1000 samples each. Missing target terminates the subscription; "
				+ "reset releases all state."
			)
		)
		. param("node_path", "String", true, "Absolute runtime /root/... path")
		. param("property", "String", true, "Existing property")
		. param("interval_ms", "int", false, "1..25000; default 16")
		. example('{"node_path":"/root/RuntimeMain/ProbeTarget","property":"position"}')
		. returns(
			"Subscription",
			{"monitor_id": "String", "status": "String", "changed": "bool", "undoable": "bool"}
		)
	)
