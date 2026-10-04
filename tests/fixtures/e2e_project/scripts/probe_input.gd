extends Node

## ProbeInput — 转发 Input 事件到 /root/RuntimeMain/ProbeTarget
##
## 当 fixture 运行后,所有 runtime/input/* 操作最终都会被 Input.parse_input_event 投递,
## 然后由这个 _input 把信息转发到 ProbeTarget 计数。
## 其它方法可订阅 count 变化,以便 assertion 通过 runtime/node/get 来观察。

var _target: Node = null


func _ready() -> void:
	_ready_target.call_deferred()


func _ready_target() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	if _target == null:
		# 退出/重启时已经清理
		return


func _unhandled_input(event: InputEvent) -> void:
	if _target == null:
		return
	if event is InputEventKey:
		_target.call("add_keys")
	elif event is InputEventMouseButton:
		_target.call("add_mouse")
	elif event is InputEventJoypadButton:
		_target.call("add_gamepad")
	elif event is InputEventScreenTouch:
		_target.call("add_touch")


func reset_fixture() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
