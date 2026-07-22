extends Node2D

## RuntimeMain — M3 fixture 根节点
##
## 包含可观测子节点 ProbeTarget 与若干 Input 中继节点。
## 启动时直接放置到主场景树中。

@onready var probe_target: Node = $ProbeTarget
@onready var probe_input: Node = $ProbeInput
@onready var probe_input_action: Node = $ProbeInputAction
@onready var probe_finished_signal: Node = $ProbeFinishedSignal
