extends Node

## ProbeFinishedSignal — 当 ProbeTarget.emit_finished 被调用时,触发一次已知事件。

func _ready() -> void:
	var target: Node = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	if target != null:
		var on_finished := func() -> void:
			EngineDebugger.send_message("gdapi", [{
				"version": 1,
				"id": 0,
				"kind": "event",
				"event": "probe.finished",
				"result": {},
			}])
		target.connect("finished", on_finished)
