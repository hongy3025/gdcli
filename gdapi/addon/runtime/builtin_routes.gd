@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

var _route_names: Array = []

func set_route_names(names: Array) -> void:
    _route_names = names

func handle(_params: Dictionary) -> Dictionary:
    return {"ok": true, "routes": _route_names}
