@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/scene_batch_service.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := Service.apply(req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code), out.get("details", {}))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("原子应用跨场景属性事务")
		. mutates()
		. desc(
			"使用 PackedScene 保留资源、owner 与实例 override；拒绝所有已打开的受影响场景，避免覆盖未保存修改。失败回滚全部已写项；恢复前校验所有场景和备份。"
		)
		. param("root", "String", false, "递归扫描根；排除生成及保护目录", "res://")
		. param("scenes", "Array[String]", false, "显式场景路径，替代 root 扫描")
		. param("selector", "Dictionary", false, "class/name(通配符)/node_path(相对场景根)；条件取交集")
		. param(
			"operations",
			"Array[Dictionary]",
			true,
			"set_property: property/value、可选 scene 与 selector；支持 typed Variant"
		)
		. param("plan_hash", "String", true, "plan 返回的哈希；绑定参数、原场景与资源依赖")
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
