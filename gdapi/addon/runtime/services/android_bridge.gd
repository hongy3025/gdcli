@tool
class_name AndroidBridge
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")

static func parse_devices(text: String) -> Array:
	var result: Array = []
	for line in text.split("\n"):
		var fields := line.strip_edges().split(" ", false)
		if fields.size() < 2 or fields[0] == "List": continue
		var item := {"serial":fields[0], "state":fields[1], "product":"", "model":"", "transport_id":""}
		for field in fields.slice(2):
			var pair := field.split(":", true, 1)
			if pair.size() == 2 and item.has(pair[0]): item[pair[0]] = pair[1]
		result.append(item)
	return result

static func devices() -> Dictionary:
	var result := _execute(["devices", "-l"], 10000)
	if not result.ok: return result
	return {"ok":true, "devices":parse_devices(result.output)}

static func deploy(body: Dictionary) -> Dictionary:
	if not bool(body.get("force", false)): return {"ok":false, "code":ErrorCodes.UNSAFE_OPERATION, "error":"export/android/deploy requires force:true"}
	var serial := String(body.get("serial", "")); var regex := RegEx.new(); regex.compile("^[A-Za-z0-9._:-]+$")
	if regex.search(serial) == null: return {"ok":false, "code":ErrorCodes.INVALID_PARAM, "error":"invalid device serial"}
	var package_name := String(body.get("package", "")); var activity := String(body.get("activity", "")); var identifier := RegEx.new(); identifier.compile("^[A-Za-z][A-Za-z0-9_.]*$")
	if identifier.search(package_name) == null or identifier.search(activity) == null: return {"ok":false, "code":ErrorCodes.INVALID_PARAM, "error":"invalid package or activity"}
	var path := PathGuard.validate(String(body.get("apk_path", "")), "read")
	if not path.ok or not path.path.to_lower().ends_with(".apk") or not FileAccess.file_exists(path.path): return {"ok":false, "code":ErrorCodes.INVALID_PATH, "error":"APK path is invalid"}
	var listed := devices(); if not listed.ok: return listed
	var selected: Array = listed.devices.filter(func(item): return item.serial == serial)
	if selected.size() != 1 or selected[0].state != "device": return {"ok":false, "code":ErrorCodes.NOT_SUPPORTED, "error":"selected device is not online"}
	var adb := _adb_path()
	if adb.is_empty() or not FileAccess.file_exists(adb): return {"ok":false, "code":ErrorCodes.NOT_FOUND, "error":"configured ADB executable not found"}
	var install := _execute(["-s", serial, "install", "-r", ProjectSettings.globalize_path(path.path)], 60000, adb)
	if not install.ok: return install
	var launch := _execute(["-s", serial, "shell", "am", "start", "-n", package_name + "/" + activity], 60000, adb)
	if not launch.ok: return launch
	return {"ok":true, "serial":serial, "installed":true, "launched":true, "undoable":false}

static func _execute(args: Array, timeout_ms: int, executable: String = "") -> Dictionary:
	var path := executable
	if path.is_empty(): path = _adb_path()
	if path.is_empty() or not FileAccess.file_exists(path): return {"ok":false, "code":ErrorCodes.NOT_FOUND, "error":"ADB executable not found"}
	var process := OS.execute_with_pipe(path, args, false)
	if process.is_empty() or not process.has_all(["stdio", "stderr", "pid"]): return {"ok":false, "code":ErrorCodes.GODOT_ERROR, "error":"ADB process could not start"}
	var stdout: FileAccess = process["stdio"]; var stderr: FileAccess = process["stderr"]; var pid := int(process["pid"]); var output := ""; var deadline := Time.get_ticks_msec() + timeout_ms
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		if stdout.get_available_bytes() > 0: output += stdout.get_as_text()
		if stderr.get_available_bytes() > 0: output += stderr.get_as_text()
		if output.length() > 65536: OS.kill(pid); break
		OS.delay_msec(10)
	if OS.is_process_running(pid): OS.kill(pid)
	while OS.is_process_running(pid): OS.delay_msec(10)
	var code := OS.get_process_exit_code(pid); stdout.close(); stderr.close()
	if code != 0: return {"ok":false, "code":ErrorCodes.GODOT_ERROR, "error":"ADB command failed", "details":{"exit_code":code}}
	return {"ok":true, "output":output}

static func _adb_path() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings == null or not settings.has_setting("export/android/adb"): return ""
	return String(settings.get_setting("export/android/adb"))
