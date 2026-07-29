@tool
class_name GdApiBulkDeployService
extends RefCounted

const Policy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const AndroidBridge := preload("res://addons/gdapi/runtime/services/android_bridge.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

static func deploy(body: Dictionary) -> Dictionary:
	var serials: Array = body.get("serials", [])
	if typeof(serials) != TYPE_ARRAY or serials.is_empty(): return _error(ErrorCodes.INVALID_PARAM, "serials is required")
	var unique: Array = []
	for serial in serials:
		if typeof(serial) != TYPE_STRING or unique.has(serial): return _error(ErrorCodes.INVALID_PARAM, "serials must be unique strings")
		unique.append(serial)
	unique.sort()
	var apk := String(body.get("apk_path", ""))
	if not FileAccess.file_exists(ProjectSettings.globalize_path(apk)): return _error(ErrorCodes.INVALID_PATH, "APK path is invalid")
	var artifact := FileAccess.get_sha256(ProjectSettings.globalize_path(apk))
	var plan_hash := _hash({"serials": unique, "apk_path": apk, "artifact": artifact, "package": body.get("package", ""), "activity": body.get("activity", "")})
	if bool(body.get("dry_run", false)): return {"ok": true, "plan_hash": plan_hash, "serials": unique, "artifact_sha256": artifact}
	if String(body.get("plan_hash", "")) != plan_hash: return _error(ErrorCodes.CONFLICT, "plan_hash does not match")
	var devices := AndroidBridge.devices()
	if not devices.ok: return devices
	var result: Array = []
	for serial in unique:
		var online := false
		for device in devices.devices:
			if device.serial == serial and device.state == "device": online = true
		if not online: result.append({"serial": serial, "ok": false, "code": ErrorCodes.NOT_SUPPORTED}); continue
		var one := AndroidBridge.deploy({"serial": serial, "apk_path": apk, "package": body.get("package", ""), "activity": body.get("activity", ""), "force": true})
		result.append({"serial": serial, "ok": one.ok, "code": "" if one.ok else String(one.get("code", ErrorCodes.GODOT_ERROR))})
	return {"ok": true, "changed": result.any(func(item): return item.ok), "undoable": false, "devices": result, "plan_hash": plan_hash}

static func _hash(value: Variant) -> String:
	var context := HashingContext.new(); context.start(HashingContext.HASH_SHA256); context.update(JSON.stringify(value).to_utf8_buffer()); return context.finish().hex_encode()

static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
