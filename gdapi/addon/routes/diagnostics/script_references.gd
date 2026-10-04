@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.extended("script_references", req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("分析脚本与场景的真实静态引用")
		. desc(
			(
				"词法扫描 extends/preload/load/class_name、函数与信号引用，"
				+ "跳过注释与字符串中的代码；场景 script 来自 SceneState。"
				+ "附着脚本随场景扫描，文件/行号保留；二进制场景行为行号为0。"
				+ "不做类型推断，动态路径/接收者明确 unknown。"
			)
		)
		. param("roots", "Array[String]", false, "扫描文件或目录", ["res://"])
		. param("path", "String", false, "单文件/目录选择，覆盖 roots")
		. param("include_addons", "bool", false, "是否扫描 addons 脚本，默认保护排除", false)
		. param("offset", "int", false, "引用分页偏移", 0)
		. param("limit", "int", false, "页大小 1–500", 100)
		. returns(
			"引用位置、声明与动态不确定性",
			{
				"items": "Array: path/line/kind/target/status/reason",
				"declarations": "Array: func/signal/class_name",
				"total": "int",
				"unknown_count": "int",
				"runtime_complete": "bool: always false; lexical analysis is not runtime inference",
				"limitations": "String",
				"scope": "Dictionary"
			}
		)
		. example('{"roots":["res://analysis"],"limit":500}')
	)
