extends Node

## ProbeInputAction — 把 input action 计数转发
##
## Godot 的 action 信号在 InputMap 上发行后无法直接 hook;
## 我们监听项目默认 ui_accept 等 action 的 `action_pressed` 信号,
## 仅在发生 add_action 时计数。

var _target: Node = null

func _ready() -> void:
	_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
	if _target != null:
		# 監听 ui_accept action 的行为,使用 _process 轮询够简单。
		pass

func _input(event: InputEvent) -> void:
	if _target == null:
		_target = get_tree().root.get_node_or_null("RuntimeMain/ProbeTarget")
		if _target == null:
			return
	if event.is_action_pressed("ui_accept", false):
		_target.call("add_action")
