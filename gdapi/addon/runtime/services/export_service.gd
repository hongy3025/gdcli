@tool
class_name GdApiExportService
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const MAX_OUTPUT_BYTES := 262144
const DRAIN_CHUNK_BYTES := 8192
const ANSI_ESCAPE_PATTERN := "\\x1b\\[[0-9;]*[A-Za-z]"
const CONTROL_CHARACTER_PATTERN := "[\\x00-\\x08\\x0b-\\x1f\\x7f]"


static func presets() -> Dictionary:
	var config := ConfigFile.new()
	var error := config.load("res://export_presets.cfg")
	if error != OK:
		return {"ok": true, "presets": []}
	var result: Array = []
	for section in config.get_sections():
		if not String(section).begins_with("preset.") or String(section).contains(".options"):
			continue
		(
			result
			. append(
				{
					"name": config.get_value(section, "name", ""),
					"platform": config.get_value(section, "platform", ""),
					"runnable": bool(config.get_value(section, "runnable", false)),
					"export_path": String(config.get_value(section, "export_path", "")),
				}
			)
		)
	result.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return {"ok": true, "presets": result}


static func run(body: Dictionary) -> Dictionary:
	var preset_name := String(body.get("preset", ""))
	var found := _find_preset(preset_name)
	if found.is_empty():
		return _err(ErrorCodes.NOT_FOUND, "export preset not found")
	var checked := PathGuard.validate(String(body.get("path", "")), "write")
	if not checked.ok:
		return checked
	if not checked.path.begins_with("res://"):
		return _err(ErrorCodes.INVALID_PATH, "export path must be inside the project")
	var output := ProjectSettings.globalize_path(checked.path)

	var parent := output.get_base_dir()
	DirAccess.make_dir_recursive_absolute(parent)
	# 子进程必须用 --recovery-mode 启动：否则它会再次加载 gdapi 编辑器插件，
	# 覆盖并删除父编辑器正在使用的 .godot/gdapi.json（实测会导致编辑器失联）。
	var args := [
		"--editor",
		"--headless",
		"--recovery-mode",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--export-pack",
		preset_name,
		output,
	]
	var process := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if process.is_empty() or not process.has_all(["stdio", "stderr", "pid"]):
		return _err(ErrorCodes.GODOT_ERROR, "export process could not start")
	var stdout: FileAccess = process["stdio"]
	var stderr: FileAccess = process["stderr"]
	var pid := int(process["pid"])
	# 管道缓冲区只有几 KiB：子进程运行期间必须持续排空，否则写出会阻塞直到超时。
	var captured := PackedByteArray()
	var deadline := (
		Time.get_ticks_msec() + clampi(int(body.get("timeout_ms", 120000)), 10000, 600000)
	)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		_drain_pipes(stdout, stderr, captured)
		OS.delay_msec(10)
	var timed_out := OS.is_process_running(pid)
	if timed_out:
		OS.kill(pid)
	while OS.is_process_running(pid):
		OS.delay_msec(10)
	_drain_pipes(stdout, stderr, captured)
	var exit_code := OS.get_process_exit_code(pid)
	stdout.close()
	stderr.close()
	var output_text := _sanitize_output(captured.get_string_from_utf8())
	if timed_out:
		if FileAccess.file_exists(output):
			DirAccess.remove_absolute(output)
		AuditLog.record(
			"export/run",
			"dangerous",
			{"preset": preset_name, "path": checked.path},
			false,
			ErrorCodes.TIMEOUT
		)
		return {
			"ok": false,
			"code": ErrorCodes.TIMEOUT,
			"error": "export timed out",
			"details": {"platform": found.platform, "preset": preset_name},
		}
	if exit_code != 0 or not FileAccess.file_exists(output):
		if FileAccess.file_exists(output):
			DirAccess.remove_absolute(output)
		if (
			output_text.to_lower().contains("template")
			or output_text.to_lower().contains("not installed")
		):
			AuditLog.record(
				"export/run",
				"dangerous",
				{"preset": preset_name, "path": checked.path},
				false,
				ErrorCodes.NOT_SUPPORTED
			)
			return {
				"ok": false,
				"code": ErrorCodes.NOT_SUPPORTED,
				"error": "export template is unavailable",
				"details": {"platform": found.platform, "preset": preset_name}
			}
		AuditLog.record(
			"export/run",
			"dangerous",
			{"preset": preset_name, "path": checked.path},
			false,
			ErrorCodes.GODOT_ERROR
		)
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "export failed",
			"details": {"exit_code": exit_code}
		}
	AuditLog.record("export/run", "dangerous", {"preset": preset_name, "path": checked.path}, true)
	return {
		"ok": true,
		"preset": preset_name,
		"path": checked.path,
		"size": FileAccess.get_file_as_bytes(output).size(),
		"sha256": FileAccess.get_sha256(output),
		"messages": output_text.split("\n", false),
		"undoable": false
	}


## 无阻塞管道在子进程运行期间必须持续排空：写满缓冲区会让子进程阻塞，
## 表现为导出"一直不结束"直到超时被杀。超出上限的输出被丢弃但仍然读走。
static func _drain_pipes(stdout: FileAccess, stderr: FileAccess, captured: PackedByteArray) -> void:
	for stream: FileAccess in [stdout, stderr]:
		while stream.get_length() > 0:
			var chunk := stream.get_buffer(DRAIN_CHUNK_BYTES)
			if chunk.is_empty():
				break
			var room := MAX_OUTPUT_BYTES - captured.size()
			if room > 0:
				captured.append_array(chunk.slice(0, mini(room, chunk.size())))


## Godot 的进度输出带 ANSI 转义与 '\r' 等控制字符；原样放进 JSON 会让响应非法。
static func _sanitize_output(text: String) -> String:
	var pattern := RegEx.new()
	if pattern.compile(ANSI_ESCAPE_PATTERN) == OK:
		text = pattern.sub(text, "", true)
	if pattern.compile(CONTROL_CHARACTER_PATTERN) == OK:
		text = pattern.sub(text, "", true)
	return text


static func _find_preset(name: String) -> Dictionary:
	for preset in presets().presets:
		if String(preset.name) == name:
			return preset
	return {}


static func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
