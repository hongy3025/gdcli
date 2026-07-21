## filesystem/write 路由: 写入文本文件 (非 .gd)

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/write"

const MAX_BYTES := 4 * 1024 * 1024

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var content: String = req.get_body("content", "")
	var force: bool = req.get_body("force", false)
	if path == "":
		res.error("path is required", ErrorCodes.MISSING_PARAM)
		return
	if content.length() > MAX_BYTES:
		res.error("content too large (max 4 MiB)", ErrorCodes.INVALID_PARAM, 400)
		return
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		res.error(checked.error, checked.code, 400)
		return
	var abs_path := ProjectSettings.globalize_path(checked.path)
	if FileAccess.file_exists(abs_path) and not force:
		AuditLog.record(ROUTE, "file", {"path": checked.path, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		res.error("filesystem/write requires force:true to overwrite", ErrorCodes.UNSAFE_OPERATION, 403)
		return
	var dir := checked.path.get_base_dir()
	if dir != "res://" and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var tmp := abs_path + ".gdcli-tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		res.error("cannot open temp file", ErrorCodes.GODOT_ERROR, 500)
		return
	f.store_string(content)
	f.close()
	DirAccess.rename_absolute(tmp, abs_path)
	AuditLog.record(ROUTE, "file", {"path": checked.path, "force": force}, true, "")
	res.json({
		"ok": true,
		"changed": true,
		"written": true,
		"undoable": false,
		"path": checked.path,
		"bytes": content.length(),
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("写入文本文件 (非脚本资源)")
		.desc("覆盖需 force:true。写入通过 temp file + rename 原子化。")
		.param("path", "String", true, "res:// 文件路径")
		.param("content", "String", true, "完整文本内容")
		.param("force", "bool", false, "覆盖已有文件需为 true", "false")
		.example("{\"path\":\"res://notes/readme.md\",\"content\":\"...\",\"force\":true}")
		.returns("write 结果", {
			"ok": "bool",
			"changed": "bool",
			"written": "bool",
			"undoable": "bool, false",
			"path": "String",
			"bytes": "int",
		})
	)
