## runtime/debug/performance — 自定义 Performance monitor 读

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var payload: Dictionary = req.body
	var names: Array = payload.get("monitors", [])
	var values: Dictionary = {}
	if names.is_empty():
		for m in Performance.get_custom_monitor_names():
			values[m] = Performance.get_custom_monitor(m)
	else:
		for n in names:
			values[String(n)] = Performance.get_custom_monitor(String(n))
	res.json({"values": values, "ok": true})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 Performance 自定义 monitor 值")
		.desc("不指定 monitors 时返回所有自定义 monitor;指定后只返回列表中的项。")
		.param("monitors", "Array", false, "名字字符串数组,默认全部", "[]")
		.returns("结果", {
			"values": "Object, name->value 映射",
			"ok": "bool",
		})
	)
