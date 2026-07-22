## runtime/input/sequence — 顺序播放多个输入事件
##
## events 最多 100 项,每项 {after_ms, route, data};累计 after_ms <= 10000ms。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var ops := load("res://addons/gdapi/runtime/runtime_input_ops.gd")
	var result: Dictionary = await ops.sequence(req.body)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "sequence failed")), String(result.get("code", "godot_error")), 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("顺序触发多个输入事件")
		.desc("events 是按 after_ms 延迟触发的输入事件列表;每项指向 runtime/input/* 子路由。最多 100 项,累计 10 秒。")
		.param("events", "Array", true, "数组,每项 {after_ms, route, data}", "[]")
		.example("{\"events\":[{\"after_ms\":0,\"route\":\"runtime/input/action\",\"data\":{\"action\":\"ui_accept\",\"pressed\":true}}]}")
		.returns("结果", {
			"changed": "bool",
			"undoable": "bool",
			"event_type": "String, sequence",
			"events": "int, 实际触发事件数",
		})
	)
