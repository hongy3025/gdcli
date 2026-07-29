extends Node

## ProbeInputAction — 把 input action 计数转发
##
## Godot 的 action 信号在 InputMap 上发行后无法直接 hook;
## 我们监听项目默认 ui_accept 等 action 的 `action_pressed` 信号,
## 仅在发生 add_action 时计数。

var _target: Node = null
var _previous_pressed := false

func _ready() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_previous_pressed = Input.is_action_pressed("ui_accept")

func _process(_delta: float) -> void:
	if _target == null:
		_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
		if _target == null:
			return
	var pressed := Input.is_action_pressed("ui_accept")
	if pressed and not _previous_pressed:
		_target.call("add_action")
	_previous_pressed = pressed

func reset_fixture() -> void:
	Input.action_release("ui_accept")
	_previous_pressed = false
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
