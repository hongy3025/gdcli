extends Node

## ProbeFinishedSignal — 当 ProbeTarget.emit_finished 被调用时,触发一次已知事件。

var _target: Node = null
var _on_finished: Callable = Callable()
var event_count: int = 0
var temporary_finished_connections: int:
	get:
		if _target == null:
			return 0
		var count := 0
		for connection in _target.get_signal_connection_list(&"finished"):
			var callback: Variant = connection.get("callable", Callable())
			if typeof(callback) == TYPE_CALLABLE and callback != _on_finished:
				count += 1
		return count
var runtime_wait_timer_count: int:
	get:
		return get_tree().get_nodes_in_group(&"gdapi_runtime_wait_timer").size()


func _ready() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_bind_fixture_connection()


func _bind_fixture_connection() -> void:
	if _target != null:
		if not _on_finished.is_valid():
			_on_finished = func() -> void:
				event_count += 1
				(
					EngineDebugger
					. send_message(
						"gdapi:protocol",
						[
							{
								"version": 1,
								"id": 0,
								"kind": "event",
								"event": "probe.finished",
								"result": {},
							}
						]
					)
				)
		if not _target.is_connected("finished", _on_finished):
			_target.connect("finished", _on_finished)


func reset_fixture() -> void:
	event_count = 0
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_bind_fixture_connection()
