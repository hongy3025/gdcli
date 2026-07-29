extends Node2D

## RuntimeMain — M3 fixture 根节点
##
## 包含可观测子节点 ProbeTarget 与若干 Input 中继节点。
## 启动时直接放置到主场景树中。

@onready var probe_target: Node = $ProbeTarget
@onready var probe_input: Node = $ProbeInput
@onready var probe_input_action: Node = $ProbeInputAction
@onready var probe_finished_signal: Node = $ProbeFinishedSignal

func reset_fixture() -> Dictionary:
	_remove_runtime_children(self)
	probe_target.reset_fixture()
	return {"changed": true, "undoable": false}

func _remove_runtime_children(parent: Node) -> void:
	for child in parent.get_children():
		if child == probe_target or child == probe_input or child == probe_input_action or child == probe_finished_signal:
			_remove_runtime_children(child)
		else:
			child.free()
