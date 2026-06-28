@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var mode: String = req.get_body("mode", "read")
	var result := PathGuard.validate(path, mode)
	if not result.ok:
		res.error(result.error, result.code, result.status)
		return
	res.json({"ok": true, "path": result.path, "mode": mode})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("校验并规范化项目路径")
		.desc("用于验证 gdapi 路径安全策略；返回规范化后的 res:// 或 user:// 路径")
		.param("path", "String", true, "待校验路径")
		.param("mode", "String", false, "read、write 或 delete", "read")
		.returns("路径校验结果", {"ok":"bool", "path":"String", "mode":"String"})
	)
