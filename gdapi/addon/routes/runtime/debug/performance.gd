## runtime/debug/performance — 自定义 Performance monitor 读

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/debug/performance", false)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 Performance 自定义 monitor 值")
		.desc("不指定 monitors 时返回所有自定义 monitor;指定后只返回列表中的项。")
		.param("monitors", "Array", false, "名字字符串数组,默认全部", "[]")
		.example("{\"monitors\":[\"my_counter\"]}")
		.returns("结果", {
			"values": "Object, name->value 映射",
			"ok": "bool",
		})
	)
