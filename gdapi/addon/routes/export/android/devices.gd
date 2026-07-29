@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/android_bridge.gd")


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.devices()
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出 Android 设备")
		. returns("ADB 设备列表", {"ok": "bool", "devices": "Array"})
		. example("{}")
	)
