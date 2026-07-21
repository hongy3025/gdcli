## 场景保存路由处理器
##
## 提供保存 Godot 场景文件的 API 端点。
## 支持保存当前场景或另存为新路径，自动创建不存在的目录。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "scene/save"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var new_path: String = req.get_body("new_path", "")
	var force: bool = req.get_body("force", false)

	if scene_path.is_empty():
		res.error("scene_path is required", ErrorCodes.MISSING_PARAM)
		return

	# 校验源路径
	var checked := PathGuard.validate(scene_path, "read")
	if not checked.ok:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, checked.code)
		res.error(checked.error, checked.code, checked.status)
		return
	scene_path = checked.path

	# 检查场景文件是否存在
	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, ErrorCodes.NOT_FOUND, 404)
		return

	# 确定保存路径
	var save_path := scene_path
	if not new_path.is_empty():
		checked = PathGuard.validate(new_path, "write")
		if not checked.ok:
			AuditLog.record(ROUTE, "dangerous", {"new_path": new_path}, false, checked.code)
			res.error(checked.error, checked.code, checked.status)
			return
		save_path = checked.path
		# 目标已存在时要求 force
		if FileAccess.file_exists(ProjectSettings.globalize_path(save_path)):
			if not ErrorCodes.require_force(res, force, ROUTE):
				AuditLog.record(ROUTE, "dangerous", {"target": save_path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
				return
		# 自动创建目标目录
		var new_dir := save_path.get_base_dir()
		if new_dir != "res://":
			var abs_dir := ProjectSettings.globalize_path(new_dir)
			if not DirAccess.dir_exists_absolute(abs_dir):
				DirAccess.make_dir_recursive_absolute(abs_dir)

	# 加载场景资源
	var scene := load(scene_path)
	if not scene:
		AuditLog.record(ROUTE, "dangerous", {"target": scene_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to load scene: " + scene_path, ErrorCodes.GODOT_ERROR, 500)
		return

	var save_result := ResourceSaver.save(scene, save_path)
	if save_result != OK:
		AuditLog.record(ROUTE, "dangerous", {"target": save_path}, false, ErrorCodes.GODOT_ERROR)
		res.error("failed to save scene: " + str(save_result), ErrorCodes.GODOT_ERROR, 500, {"godot_error": save_result})
		return

	AuditLog.record(ROUTE, "dangerous", {"source": scene_path, "target": save_path}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": save_path,
	})
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("保存 Godot 场景文件")
		.desc("支持保存到原路径或另存为新路径；另存目标已存在时需 force:true")
		.param("scene_path", "String", true, "场景路径")
		.param("new_path", "String", false, "另存目标路径，留空则覆盖原路径", "")
		.param("force", "bool", false, "另存目标已存在时需为 true")
		.example("{\"scene_path\":\"res://test.tscn\",\"force\":true}")
		.returns("保存结果", {
			"ok": "bool",
			"changed": "bool, 是否产生变更",
			"saved": "bool, 是否已保存到磁盘",
			"undoable": "bool, 始终为 false",
			"path": "String, 实际保存路径",
		})
	)
