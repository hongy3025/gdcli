## runtime/debug/breakpoints — 显式 not_supported,除非 EditorDebugger 报告支持

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.error("editor breakpoint mutation is unavailable in runtime probe v1", "not_supported", 501)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("编辑断点")
		.desc("M3 不支持此能力;EditorDebugger session 不暴露 break/bp_set 给 probe。返回 not_supported。")
		.returns("错误结果", {"error": "String", "code": "not_supported"})
	)
