@tool
class_name GdApiBulkDeployService
extends RefCounted

const AndroidBridge := preload("res://addons/gdapi/runtime/services/android_bridge.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


static func deploy(body: Dictionary) -> Dictionary:
	var planned := plan(body)
	if not planned.ok:
		return planned
	if bool(body.get("dry_run", false)):
		return planned
	return apply(body)


static func plan(body: Dictionary, bridge: Variant = null) -> Dictionary:
	var serials: Array = body.get("serials", [])
	if typeof(serials) != TYPE_ARRAY or serials.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "serials is required")
	var unique: Array = []
	for serial in serials:
		if typeof(serial) != TYPE_STRING or String(serial).is_empty() or unique.has(serial):
			return _error(ErrorCodes.INVALID_PARAM, "serials must be unique strings")
		unique.append(serial)
	unique.sort()
	var apk := String(body.get("apk_path", ""))
	if not FileAccess.file_exists(ProjectSettings.globalize_path(apk)):
		return _error(ErrorCodes.INVALID_PATH, "APK path is invalid")
	var artifact := FileAccess.get_sha256(ProjectSettings.globalize_path(apk))
	var listed := _devices(bridge)
	if not listed.ok:
		return listed
	var snapshot := _device_snapshot(listed.devices)
	var plan_hash := _hash(
		{
			"serials": unique,
			"devices": snapshot,
			"apk_path": apk,
			"artifact_sha256": artifact,
			"package": body.get("package", ""),
			"activity": body.get("activity", "")
		}
	)
	return {
		"ok": true,
		"plan_hash": plan_hash,
		"serials": unique,
		"devices": snapshot,
		"artifact_sha256": artifact
	}


static func apply(body: Dictionary, bridge: Variant = null) -> Dictionary:
	var planned := plan(body, bridge)
	if not planned.ok:
		return planned
	if String(body.get("plan_hash", "")) != String(planned.plan_hash):
		return _error(ErrorCodes.CONFLICT, "plan_hash does not match")
	var result: Array = []
	for serial in planned.serials:
		var state := _device_state(planned.devices, String(serial))
		if state.is_empty():
			result.append({"serial": serial, "status": "missing", "ok": false})
			continue
		if state != "device":
			result.append({"serial": serial, "status": "offline", "ok": false})
			continue
		var one := _deploy(
			{
				"serial": serial,
				"apk_path": String(body.get("apk_path", "")),
				"package": body.get("package", ""),
				"activity": body.get("activity", "")
			},
			bridge
		)
		result.append(
			{
				"serial": serial,
				"status": "deployed" if one.ok else "failed",
				"ok": one.ok,
				"code": "" if one.ok else String(one.get("code", ErrorCodes.GODOT_ERROR))
			}
		)
	return {
		"ok": true,
		"changed": result.any(func(item): return item.ok),
		"undoable": false,
		"devices": result,
		"plan_hash": planned.plan_hash,
		"artifact_sha256": planned.artifact_sha256
	}


static func _devices(bridge: Variant) -> Dictionary:
	if bridge != null:
		var result: Variant = bridge.call("devices")
		return (
			result
			if typeof(result) == TYPE_DICTIONARY
			else _error(ErrorCodes.GODOT_ERROR, "device provider returned an invalid result")
		)
	return AndroidBridge.devices()


static func _deploy(body: Dictionary, bridge: Variant = null) -> Dictionary:
	if bridge != null:
		var result: Variant = bridge.call("deploy", body)
		return (
			result
			if typeof(result) == TYPE_DICTIONARY
			else _error(ErrorCodes.GODOT_ERROR, "device provider returned an invalid result")
		)
	return AndroidBridge.deploy(body)


static func _device_snapshot(devices: Array) -> Array:
	var snapshot: Array = []
	for device in devices:
		if typeof(device) != TYPE_DICTIONARY:
			continue
		snapshot.append(
			{"serial": String(device.get("serial", "")), "state": String(device.get("state", ""))}
		)
	snapshot.sort_custom(func(left, right): return left.serial < right.serial)
	return snapshot


static func _device_state(devices: Array, serial: String) -> String:
	for device in devices:
		if String(device.get("serial", "")) == serial:
			return String(device.get("state", ""))
	return ""


static func _hash(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(value).to_utf8_buffer())
	return context.finish().hex_encode()


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
