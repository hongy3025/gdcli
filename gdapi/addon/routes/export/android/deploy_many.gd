@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const Service := preload("res://addons/gdapi/runtime/services/bulk_deploy_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "export/android/deploy_many"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var policy := Policy.new(); var gate := policy.authorize("bulk_deploy", ROUTE, req.body)
	if not gate.ok:
		AuditLog.record(ROUTE, "dangerous", {"serial_count": req.get_body("serials", []).size(), "force": req.get_body("force", false)}, false, gate.code); res.error(gate.error, gate.code, ErrorCodes.http_status(gate.code)); return
	var out := Service.deploy(req.body)
	AuditLog.record(ROUTE, "dangerous", {"serial_count": req.get_body("serials", []).size(), "dry_run": req.get_body("dry_run", false)}, out.ok, String(out.get("code", "")))
	if out.ok: res.json(out)
	else: res.error(out.error, out.code, ErrorCodes.http_status(out.code))

func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("确认后的多设备 Android 部署").desc("dry_run 计划包含 APK 摘要和排序后的设备；apply 必须提交未变化的 plan_hash。").param("serials", "Array[String]", true, "设备序列号").param("apk_path", "String", true, "APK 路径").param("package", "String", true, "包名").param("activity", "String", true, "Activity").param("dry_run", "bool", true, "仅规划").param("plan_hash", "String", false, "计划哈希").param("force", "bool", true, "确认部署").returns("每设备终态", {"devices": "Array", "changed": "bool", "plan_hash": "String"}).example('{"serials":["device-a"],"apk_path":"res://build/app.apk","package":"org.example","activity":"com.godot.game.GodotApp","dry_run":true,"force":true}')
