@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/uid_repair.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.repair(req.body)
	if out.ok:
		res.json(out)
	else:
		# details 必须是 Dictionary：此前把 changes(Array) 直接当第 4 个参数，
		# 失败路径会在 GDScript 里抛类型错误、响应永远发不出去（CLI 只能超时）。
		var details := {"changes": out.get("changes", [])}
		var extra: Variant = out.get("details", {})
		if typeof(extra) == TYPE_DICTIONARY:
			details.merge(extra)
		res.error(out.error, out.code, ErrorCodes.http_status(out.code), details)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("扫描并修复资源 UID")
		. param("roots", "Array[String]", false, "扫描根", ["res://"])
		. param("dry_run", "bool", false, "只规划不写入", true)
		. returns(
			"UID 计划",
			{
				"ok": "bool",
				"scanned": "int",
				"missing": "int",
				"collisions": "int",
				"changes": "Array",
				"changed": "bool",
				"undoable": "bool"
			}
		)
		. example('{"roots":["res://fixtures"],"dry_run":true}')
	)
