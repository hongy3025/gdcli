@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/diagnostics.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.extended("scene_complexity", req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("度量真实场景复杂度并评估阈值")
		. desc(
			"从 PackedScene state 展开实例与继承，不实例化节点。根深度为0；脚本计附着节点；资源计唯一外部/内建引用；连接仅序列化连接。超过阈值报告 exceeded，不当作请求失败。"
		)
		. param("roots", "Array[String]", false, "扫描文件或目录", ["res://"])
		. param("path", "String", false, "单场景/目录选择，覆盖 roots")
		. param(
			"thresholds",
			"Dictionary",
			false,
			"非负 node_count/max_depth/script_count/resource_reference_count/connection_count 上限",
			{}
		)
		. param("include_addons", "bool", false, "是否扫描 addons；生成文件及隐藏目录始终排除", false)
		. param("offset", "int", false, "场景分页偏移", 0)
		. param("limit", "int", false, "页大小 1–500", 100)
		. returns(
			"真实节点/类型/资源/连接指标及阈值结果",
			{
				"items":
				"Array: node_count/max_depth/type_counts/script_count/"
				+ "resource_references/connection_count/exceeded/within_thresholds",
				"total": "int",
				"scope": "Dictionary",
				"count_semantics": "String"
			}
		)
		. example('{"path":"res://analysis/deep.tscn","thresholds":{"node_count":3,"max_depth":2}}')
	)
