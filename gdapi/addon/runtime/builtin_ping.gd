@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
    return {
        "ok": true,
        "gdapi_version": "0.2.0",
        "editor_version": Engine.get_version_info().get("string", ""),
    }
