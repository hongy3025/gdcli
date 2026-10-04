## runtime/log/read — 增量读取运行期日志 ring buffer

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/log/read", false)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("增量读取运行期日志")
		. desc("after_cursor 表示上次读取之后的下一个 cursor;limit 默认 100,最大 500。每次最多返回 dropped 条目丢弃提示。")
		. param("after_cursor", "int", false, "上次读取之后的 cursor,默认 0 从头开始", "0")
		. param("limit", "int", false, "本次最多返回的条目数", "100")
		. example('{"after_cursor":0,"limit":50}')
		. returns(
			"读取结果",
			{
				"items": "Array, 每项 {cursor,level,message,details,ts}",
				"next_cursor": "int, 下一次读取的起点",
				"dropped": "int, 已丢弃的条目数",
			}
		)
	)
