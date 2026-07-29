@tool
class_name GdApiDiagnostics
extends RefCounted

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")


static func analyze(kind: String, body: Dictionary) -> Dictionary:
	var roots: Array = body.get("roots", ["res://"])
	var files: Array = []
	for root in roots:
		var checked := PathGuard.validate(String(root), "read")
		if not checked.ok:
			return checked
		_collect(checked.path, files)
	files.sort()
	var findings: Array = []
	match kind:
		"unused_resources":
			findings = _unused(files)
		"cycle_deps":
			findings = _cycles(files)
		"script_errors":
			findings = _script_errors(files)
	findings.sort_custom(
		func(a, b):
			var sa := _severity_rank(String(a.get("severity", "info")))
			var sb := _severity_rank(String(b.get("severity", "info")))
			if sa != sb:
				return sa < sb
			return (
				[String(a.get("path", "")), int(a.get("line", 0)), String(a.get("code", ""))]
				< [String(b.get("path", "")), int(b.get("line", 0)), String(b.get("code", ""))]
			)
	)
	return {"ok": true, "items": _page(findings, body), "total": findings.size()}


static func health(body: Dictionary) -> Dictionary:
	var result := {
		"ok": true,
		"godot": Engine.get_version_info().get("string", ""),
		"routes": 0,
		"filesystem": "ready",
		"runtime": "ready",
		"findings": {}
	}
	for kind in ["unused_resources", "cycle_deps", "script_errors"]:
		var out := analyze(kind, body)
		result.findings[kind] = int(out.get("total", 0))
	return result


static func _unused(files: Array) -> Array:
	var deps: Dictionary = {}
	for path in files:
		deps[path] = _dependencies(path)
	var reachable: Dictionary = {}
	var queue: Array = []
	var main := String(
		(
			ProjectSettings.get_setting("run/main_scene")
			if ProjectSettings.has_setting("run/main_scene")
			else ""
		)
	)
	if not main.is_empty():
		queue.append(main)
	for autoload in ProjectSettings.get_property_list():
		var name := String(autoload.get("name", ""))
		if name.begins_with("autoload/"):
			queue.append(
				(
					String(
						(
							ProjectSettings.get_setting(name)
							if ProjectSettings.has_setting(name)
							else ""
						)
					)
					. trim_prefix("*")
				)
			)
	while not queue.is_empty():
		var path := queue.pop_front()
		if reachable.has(path):
			continue
		reachable[path] = true
		for dep in deps.get(path, []):
			queue.append(dep)
	var cycles := _cycles(files)
	var cycle_paths: Dictionary = {}
	for finding in cycles:
		for path in finding.cycle:
			cycle_paths[path] = true
	var result: Array = []
	for path in files:
		if (
			path.get_extension().to_lower() in ["tres", "res", "tscn", "scn"]
			and not reachable.has(path)
			and not cycle_paths.has(path)
		):
			result.append(
				{
					"severity": "warning",
					"code": "unused_resource",
					"message": "resource is not reachable from the project entry points",
					"path": path
				}
			)
	return result


static func _cycles(files: Array) -> Array:
	var graph: Dictionary = {}
	for path in files:
		graph[path] = _dependencies(path)
	var state: Dictionary = {}
	var stack: Array = []
	var result: Array = []
	for path in files:
		_visit(path, graph, state, stack, result)
	return result


static func _visit(
	path: String, graph: Dictionary, state: Dictionary, stack: Array, result: Array
) -> void:
	if state.get(path, 0) == 2:
		return
	if state.get(path, 0) == 1:
		var index := stack.find(path)
		if index >= 0:
			var cycle: Array = stack.slice(index)
			cycle.append(path)
			var body := cycle.slice(0, cycle.size() - 1)
			body.sort()
			var start := cycle.find(body[0])
			var normalized: Array = []
			for i in range(cycle.size() - 1):
				normalized.append(cycle[(start + i) % (cycle.size() - 1)])
			normalized.append(normalized[0])
			var key := ",".join(normalized)
			for existing in result:
				if ",".join(existing.cycle) == key:
					return
			result.append(
				{
					"severity": "error",
					"code": "dependency_cycle",
					"message": "resource dependency cycle detected",
					"path": normalized[0],
					"cycle": normalized
				}
			)
		return
	state[path] = 1
	stack.append(path)
	for dep in graph.get(path, []):
		_visit(dep, graph, state, stack, result)
	stack.pop_back()
	state[path] = 2


static func _script_errors(files: Array) -> Array:
	var result: Array = []
	for path in files:
		if path.get_extension().to_lower() != "gd":
			continue
		var source := FileAccess.get_file_as_string(path)
		var script := GDScript.new()
		script.source_code = source
		if script.reload() != OK:
			result.append(
				{
					"severity": "error",
					"code": "script_reload_error",
					"message": "GDScript failed to reload",
					"path": path,
					"line": 0,
					"column": 0
				}
			)
	return result


static func _dependencies(path: String) -> Array:
	var result: Array = []
	var text := FileAccess.get_file_as_string(path)
	var regex := RegEx.new()
	regex.compile('path=\\"(res://[^\\"]+)\\"')
	for match in regex.search_all(text):
		result.append(String(match.get_string(1)))
	return result


static func _collect(path: String, result: Array) -> void:
	if FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		result.append(path)
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not name.begins_with("."):
			_collect(path.trim_suffix("/") + "/" + name, result)
		name = dir.get_next()
	dir.list_dir_end()


static func _page(values: Array, body: Dictionary) -> Array:
	var offset := maxi(0, int(body.get("offset", 0)))
	var limit := clampi(int(body.get("limit", 100)), 1, 500)
	return values.slice(offset, mini(values.size(), offset + limit))


static func _severity_rank(value: String) -> int:
	return {"error": 0, "warning": 1, "info": 2}.get(value, 3)
