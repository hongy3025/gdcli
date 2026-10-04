class_name AnalysisFixtureFlow
extends "res://analysis/base.gd"

signal pulse(value: int)
const DATA = preload("res://analysis/data.tres")
# preload("res://analysis/comment_only.tres")
const TEXT = 'load("res://analysis/string_only.tres"); fake_signal.emit()'
const MULTILINE = """preload("res://analysis/triple_string_only.tres")
emit_signal("fake_signal")"""


func exercise(dynamic_path: String, dynamic_signal: String, dynamic_callable: Callable) -> void:
	var loaded = load("res://analysis/base.gd")
	var computed = load(dynamic_path)
	pulse.connect(_on_pulse)
	pulse.connect(dynamic_callable)
	pulse.emit(1)
	emit_signal(&"pulse", 2)
	emit_signal(dynamic_signal, 3)
	_on_pulse(4)
	base_method()
	if loaded == computed:
		return


func _on_pulse(_value: int) -> void:
	pass
