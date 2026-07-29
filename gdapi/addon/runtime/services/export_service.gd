@tool
class_name GdApiExportService
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

static func presets() -> Dictionary:
	var config := ConfigFile.new(); var error := config.load("res://export_presets.cfg")
	if error != OK: return {"ok":true, "presets":[]}
	var result: Array = []
	for section in config.get_sections():
		if not String(section).begins_with("preset.") or String(section).contains(".options"): continue
		result.append({"name":config.get_value(section, "name", ""), "platform":config.get_value(section, "platform", ""), "runnable":bool(config.get_value(section, "runnable", false)), "export_path":String(config.get_value(section, "export_path", "")), "templates":_template_available(String(config.get_value(section, "platform", "")))})
	result.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return {"ok":true, "presets":result}

static func run(body: Dictionary) -> Dictionary:
	var preset_name := String(body.get("preset", "")); var found := _find_preset(preset_name)
	if found.is_empty(): return _err(ErrorCodes.NOT_FOUND, "export preset not found")
	var checked := PathGuard.validate(String(body.get("path", "")), "write")
	if not checked.ok: return checked
	if not checked.path.begins_with("res://"): return _err(ErrorCodes.INVALID_PATH, "export path must be inside the project")
	var output := ProjectSettings.globalize_path(checked.path)
	if FileAccess.file_exists(output) and not bool(body.get("force", false)): return _err(ErrorCodes.CONFLICT, "export destination exists")
	var parent := output.get_base_dir(); DirAccess.make_dir_recursive_absolute(parent)
	var flag := "--export-pack" if String(found.platform) != "Android" else "--export-debug"
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), flag, preset_name, output]
	var process := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if process.is_empty() or not process.has_all(["stdio", "stderr", "pid"]): return _err(ErrorCodes.GODOT_ERROR, "export process could not start")
	var stdout: FileAccess = process["stdio"]; var stderr: FileAccess = process["stderr"]; var pid := int(process["pid"]); var output_text := ""; var deadline := Time.get_ticks_msec() + int(body.get("timeout_ms", 120000))
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		output_text += _drain(stdout, stderr)
		if output_text.length() > 262144: OS.kill(pid); break
		OS.delay_msec(10)
	output_text += _drain(stdout, stderr)
	if OS.is_process_running(pid): OS.kill(pid)
	while OS.is_process_running(pid): OS.delay_msec(10)
	var exit_code := OS.get_process_exit_code(pid); stdout.close(); stderr.close()
	if exit_code != 0 or not FileAccess.file_exists(output):
		if FileAccess.file_exists(output): DirAccess.remove_absolute(output)
		if output_text.to_lower().contains("template") or output_text.to_lower().contains("not installed"): return {"ok":false, "code":ErrorCodes.NOT_SUPPORTED, "error":"export template is unavailable", "details":{"platform":found.platform, "preset":preset_name}}
		return {"ok":false, "code":ErrorCodes.GODOT_ERROR, "error":"export failed", "details":{"exit_code":exit_code}}
	AuditLog.record("export/run", "dangerous", {"preset":preset_name, "path":checked.path}, true)
	return {"ok":true, "preset":preset_name, "path":checked.path, "size":FileAccess.get_file_as_bytes(output).size(), "sha256":FileAccess.get_sha256(output), "messages":output_text.split("\n", false), "undoable":false}

static func _find_preset(name: String) -> Dictionary:
	for preset in presets().presets:
		if String(preset.name) == name: return preset
	return {}

static func _template_available(platform: String) -> bool:
	return platform != "Android" or FileAccess.file_exists(ProjectSettings.globalize_path("res://.godot/export_template_check"))

static func _drain(stdout: FileAccess, stderr: FileAccess) -> String:
	var text := ""
	if stdout.get_available_bytes() > 0: text += stdout.get_as_text()
	if stderr.get_available_bytes() > 0: text += stderr.get_as_text()
	return text

static func _err(code: String, message: String) -> Dictionary: return {"ok":false, "code":code, "error":message}
