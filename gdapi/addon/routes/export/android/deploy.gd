@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/android_bridge.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.deploy(req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, 400, out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("部署并启动单个 Android 设备")
		. param("serial", "String", true, "精确设备序列号")
		. param("apk_path", "String", true, "项目内 APK")
		. param("package", "String", true, "包名")
		. param("activity", "String", true, "Activity")
		. param("force", "bool", true, "确认部署")
		. returns(
			"部署结果", {"ok": "bool", "serial": "String", "installed": "bool", "launched": "bool"}
		)
		. example(
			'{"serial":"emulator-5554","apk_path":"res://build/app.apk","package":"org.example.app","activity":"com.godot.game.GodotApp","force":true}'
		)
	)
