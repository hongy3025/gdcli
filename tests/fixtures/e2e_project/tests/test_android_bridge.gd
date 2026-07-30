extends RefCounted

const Bridge := preload("res://addons/gdapi/runtime/services/android_bridge.gd")


func _init() -> void:
	var devices := Bridge.parse_devices(
		(
			"List of devices attached\\n"
			+ "emulator-5554 device product:sdk model:Pixel_8 transport_id:1\\n"
			+ "ABC unauthorized transport_id:2\\n"
		)
	)
	assert(devices.size() == 2)
	assert(devices[0].serial == "emulator-5554")
	assert(devices[1].state == "unauthorized")
