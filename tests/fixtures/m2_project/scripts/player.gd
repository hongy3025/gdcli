extends Node2D

signal health_changed(new_value: int)

var speed: int = 10

func _on_health_changed(new_value: int) -> void:
	pass

func take_damage(amount: int) -> void:
	health_changed.emit(amount)
