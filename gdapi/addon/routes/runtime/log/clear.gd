## runtime/log/clear — 清空运行期日志 ring buffer

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/log/clear", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("清空运行期日志 ring buffer")
		. desc("返回 cleared(已清理条目数)和 next_cursor=0。")
		. returns(
			"清理结果",
			{
				"cleared": "int",
				"next_cursor": "int",
			}
		)
	)
