extends Node

## ProbeFinishedSignal — 当 ProbeTarget.emit_finished 被调用时,触发一次已知事件。

var _target: Node = null
var _on_finished: Callable = Callable()
var event_count: int = 0

func _ready() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_bind_fixture_connection()

func _bind_fixture_connection() -> void:
	if _target != null:
		if not _on_finished.is_valid():
			_on_finished = func() -> void:
				event_count += 1
				EngineDebugger.send_message("gdapi:protocol", [{
					"version": 1,
					"id": 0,
					"kind": "event",
					"event": "probe.finished",
					"result": {},
				}])
		if not _target.is_connected("finished", _on_finished):
			_target.connect("finished", _on_finished)

func reset_fixture() -> void:
	event_count = 0
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_bind_fixture_connection()
