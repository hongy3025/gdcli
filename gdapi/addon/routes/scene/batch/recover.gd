@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/scene_batch_service.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := Service.recover(req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code), out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("原子恢复完整场景事务")
		. mutates()
		. desc(
			"使用 PackedScene 保留资源、owner 与实例 override；拒绝所有已打开的受影响场景，避免覆盖未保存修改。失败回滚全部已写项；恢复前校验所有场景和备份。"
		)
		. param("operation_id", "String", true, "apply 返回的事务 ID")
		. returns(
			"事务结果",
			{
				"ok": "bool",
				"plan_hash": "String",
				"operation_id": "String, apply only",
				"operations": "Array, plan/validate",
				"warnings": "Array"
			}
		)
	)
