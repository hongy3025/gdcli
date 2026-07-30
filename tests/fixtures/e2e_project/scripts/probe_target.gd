extends Node2D

## ProbeTarget — 可观测 counter 和 signal 用于 runtime assertion

var counter: int = 0
var spawn_position: Vector2 = Vector2(10, 20)
var input_keys: int = 0
var input_mouse: int = 0
var input_gamepad: int = 0
var input_touch: int = 0
var input_actions: int = 0
var _reset_epoch: int = 0
var _pending_timers: Array[Dictionary] = []

signal counted(value: int)
signal finished


## 在 autoload 中,声明可被 runtime/node/call 调用的方法名清单
func _init() -> void:
	set_meta(
		"gdapi_callable_methods",
		PackedStringArray(
			[
				"increment",
				"increment_later",
				"emit_finished",
				"emit_known_logs",
				"block_then_emit_finished",
				"add_keys",
				"add_mouse",
				"add_gamepad",
				"add_touch",
				"add_action",
				"reset_shared_fixture",
				"prepare_capture_fixture",
				"probe_capture_boundary",
			]
		)
	)


func increment(amount: int) -> int:
	counter += int(amount)
	counted.emit(counter)
	return counter


func increment_later(amount: int, after_ms: int) -> void:
	var epoch := _reset_epoch
	var timer := get_tree().create_timer(after_ms / 1000.0)
	var callback: Callable = func() -> void:
		if epoch == _reset_epoch:
			increment(int(amount))
	_pending_timers.append({"timer": timer, "callback": callback})
	timer.timeout.connect(callback)


func reset_fixture() -> void:
	_reset_epoch += 1
	_cancel_pending_timers()
	counter = 0
	spawn_position = Vector2(10, 20)
	position = Vector2.ZERO
	rotation = 0.0
	rotation_degrees = 0.0
	scale = Vector2.ONE
	skew = 0.0
	visible = true
	modulate = Color.WHITE
	self_modulate = Color.WHITE
	process_mode = Node.PROCESS_MODE_INHERIT
	input_keys = 0
	input_mouse = 0
	input_gamepad = 0
	input_touch = 0
	input_actions = 0
	_disconnect_signal_connections(&"counted")
	_disconnect_signal_connections(&"finished")
	for sibling in get_parent().get_children():
		if sibling != self and sibling.has_method("reset_fixture"):
			sibling.call("reset_fixture")


func reset_shared_fixture() -> Dictionary:
	var runtime_probe := get_tree().root.get_node_or_null("GdApiRuntimeProbe")
	if runtime_probe == null or not runtime_probe.has_method("reset_shared_fixture"):
		return {
			"ok": false,
			"changed": false,
			"undoable": false,
			"code": "not_supported",
			"error": "fixture runtime probe reset helper is unavailable",
		}
	return runtime_probe.call("reset_shared_fixture")


func prepare_capture_fixture(mode: String) -> Dictionary:
	var runtime_main := get_parent()
	if runtime_main == null or not runtime_main.has_method("prepare_capture_fixture"):
		return {"ok": false, "error": "capture fixture is unavailable"}
	return runtime_main.call("prepare_capture_fixture", mode)


func probe_capture_boundary(mode: String) -> Dictionary:
	var runtime_main := get_parent()
	if runtime_main == null or not runtime_main.has_method("probe_capture_boundary"):
		return {"ok": false, "error": "capture boundary fixture is unavailable"}
	return runtime_main.call("probe_capture_boundary", mode)


func _cancel_pending_timers() -> void:
	for entry in _pending_timers:
		var timer: Variant = entry.get("timer", null)
		var callback: Variant = entry.get("callback", Callable())
		if (
			timer != null
			and typeof(callback) == TYPE_CALLABLE
			and timer.timeout.is_connected(callback)
		):
			timer.timeout.disconnect(callback)
	_pending_timers.clear()


func _disconnect_signal_connections(signal_name: StringName) -> void:
	for connection in get_signal_connection_list(signal_name):
		var callback: Variant = connection.get("callable", Callable())
		if typeof(callback) == TYPE_CALLABLE and callback.is_valid():
			disconnect(signal_name, callback)


func emit_finished() -> void:
	finished.emit()


func block_then_emit_finished(block_ms: int) -> void:
	OS.delay_msec(maxi(block_ms, 0))
	finished.emit()


func emit_known_logs() -> void:
	print_rich("[color=cyan]known-info:[/color] hello from probe target")
	printerr("known-error: synthetic error for assertion")


func add_keys() -> void:
	input_keys += 1


func add_mouse() -> void:
	input_mouse += 1


func add_gamepad() -> void:
	input_gamepad += 1


func add_touch() -> void:
	input_touch += 1


func add_action() -> void:
	input_actions += 1
