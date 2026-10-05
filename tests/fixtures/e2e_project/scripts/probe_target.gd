extends Node2D

## ProbeTarget — 可观测 counter 和 signal 用于 runtime assertion

signal counted(value: int)
signal finished
var counter: int = 0
var spawn_position: Vector2 = Vector2(10, 20)
var input_keys: int = 0
var input_mouse: int = 0
var input_gamepad: int = 0
var input_touch: int = 0
var input_actions: int = 0


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
	var timer := get_tree().create_timer(after_ms / 1000.0)
	timer.timeout.connect(func() -> void: increment(amount), CONNECT_ONE_SHOT)


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
