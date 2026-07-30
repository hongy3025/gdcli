## runtime/input/sequence — 顺序播放多个输入事件
##
## events 最多 100 项,每项 {after_ms, route, data};累计 after_ms <= 10000ms。

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/sequence", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("顺序触发多个输入事件")
		. desc("events 是按 after_ms 延迟触发的输入事件列表;每项指向 runtime/input/* 子路由。最多 100 项,累计 10 秒。")
		. param("events", "Array", true, "数组,每项 {after_ms, route, data}", "[]")
		. example(
			(
				'{"events":[{"after_ms":0,"route":"runtime/input/action",'
				+ '"data":{"action":"ui_accept","pressed":true}}]}'
			)
		)
		. returns(
			"结果",
			{
				"changed": "bool",
				"undoable": "bool",
				"event_type": "String, sequence",
				"events": "int, 实际触发事件数",
			}
		)
	)
