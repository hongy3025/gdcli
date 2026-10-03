@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.extended("signal_flow", req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("分析实际场景连接与脚本信号流")
		. desc(
			"SceneState 序列化连接及词法信号声明/emit/connect 图；静态连接绑定场景节点。"
			+ "动态接收者/Callable 明确 unknown；"
			+ "resolved 不表示运行时安全或方法有效。扫描不执行场景脚本。"
		)
		. param("roots", "Array[String]", false, "扫描文件或目录", ["res://"])
		. param("path", "String", false, "单文件/目录选择，覆盖 roots")
		. param("include_addons", "bool", false, "默认排除 addons；隐藏目录、生成 uid/import 和目录链接始终排除", false)
		. param("offset", "int", false, "连接分页偏移", 0)
		. param("limit", "int", false, "连接页大小 1–500", 100)
		. returns(
			"真实连接图及不确定边界",
			{
				"items": "Array: path/line/source/signal/method/target/scene/status",
				"signals": "Array: script signal declarations",
				"total": "int",
				"unknown_count": "int",
				"runtime_complete": "bool: always false; runtime graph is not inferred",
				"limitations": "String",
				"scope": "Dictionary"
			}
		)
		. example('{"path":"res://analysis/deep.tscn","limit":500}')
	)
