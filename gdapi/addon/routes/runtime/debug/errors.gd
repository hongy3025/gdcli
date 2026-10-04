## runtime/debug/errors — 列出运行期已知错误

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/debug/errors", false)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出运行期错误")
		. desc("M3 仅返回空列表,后续版本加入详细回溯。返回结构稳定。")
		. returns(
			"结果",
			{
				"items": "Array, M3 为空",
				"ok": "bool",
			}
		)
	)
