extends Node

## ProbeInputAction — 把 input action 计数转发
##
## Poll Input state so synthetic InputEventAction propagation is not required.

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
