extends Control

signal completed
var counter := 0
var frames := 0


func _ready() -> void:
	set_meta("gdapi_runtime_dedicated", true)
	set_meta("gdapi_callable_methods", PackedStringArray(["increment"]))


func _process(_delta: float) -> void:
	frames += 1
	if frames % 5 == 0:
		completed.emit()


func increment() -> int:
	counter += 1
	return counter
