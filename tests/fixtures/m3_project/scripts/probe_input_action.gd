extends Node

## ProbeInputAction — 把 input action 计数转发
##
## InputEventAction 经过 Input.parse_input_event 后会可靠进入 _input；这里按
## false→true transition 计数，避免同一帧 release→press 被轮询丢失。

var _target: Node = null
var _previous_pressed := false

func _ready() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	_previous_pressed = Input.is_action_pressed("ui_accept")

func _input(event: InputEvent) -> void:
	if not event is InputEventAction or String(event.action) != "ui_accept":
		return
	if _target == null:
		_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
		if _target == null:
			return
	var pressed: bool = event.pressed
	if pressed and not _previous_pressed:
		_target.call("add_action")
	_previous_pressed = pressed

func reset_fixture() -> void:
	Input.action_release("ui_accept")
	_previous_pressed = false
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
