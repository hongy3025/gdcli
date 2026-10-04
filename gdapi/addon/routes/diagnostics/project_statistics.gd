@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.extended("project_statistics", req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("统计实际项目源文件与资源类型")
		. desc(
			(
				"真实 FileAccess bytes 与 ResourceLoader 类型计数；"
				+ "resource_count 包括 scripts/scenes，非独立互斥类别。"
				+ "始终排除隐藏/.godot/uid/import/目录链接；addons 默认排除。"
				+ "只读，不触碰生成或保护文件。"
			)
		)
		. param("roots", "Array[String]", false, "扫描文件或目录；重叠根去重", ["res://"])
		. param("path", "String", false, "单文件/目录选择，覆盖 roots")
		. param("include_addons", "bool", false, "显式包含 addons 源文件", false)
		. returns(
			"精确源文件计数、大小与类型",
			{
				"file_count": "int",
				"bytes": "int",
				"script_count": "int",
				"scene_count": "int",
				"resource_count": "int",
				"type_counts": "Dictionary",
				"extension_counts": "Dictionary",
				"scope": "Dictionary",
				"count_semantics": "String"
			}
		)
		. example('{"roots":["res://analysis"]}')
	)
