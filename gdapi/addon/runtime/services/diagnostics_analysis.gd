@tool
extends RefCounted

const ScriptAnalysis := preload(
	"res://addons/gdapi/runtime/services/diagnostics_script_analysis.gd"
)
const LIMITATIONS := (
	"Lexical GDScript analysis, not type inference: computed paths, runtime signals, "
	+ "reflection, inherited/external callables and runtime connections remain unknown. "
	+ "No safety conclusion is implied."
)


static func analyze(kind: String, files: Array, body: Dictionary) -> Dictionary:
	var scope := {
		"include_addons": body.get("include_addons", false),
		"excluded":
		["hidden directories/files (including .godot)", "*.uid", "*.import", "directory symlinks"],
		"read_only": true
	}
	if not scope.include_addons:
		scope.excluded.append("res://addons/**")
	if kind == "project_statistics":
		return _statistics(files, scope)
	if kind == "scene_complexity":
		return _complexity(files, body, scope)
	var references: Array = []
	var declarations: Array = []
	var scene_connections: Array = []
	var script_paths: Array = []
	var bindings: Dictionary = {}
	for path in files:
		if path.get_extension().to_lower() == "gd":
			if not script_paths.has(path):
				script_paths.append(path)
		elif path.get_extension().to_lower() in ["tscn", "scn"]:
			var scene := _scene(path)
			if not scene.ok:
				return scene
			scene_connections.append_array(scene.connections)
			for node_path in scene.nodes:
				var node: Dictionary = scene.nodes[node_path]
				if not String(node.get("script", "")).is_empty():
					references.append(
						{
							"path": node.get("origin", path),
							"line": node.get("script_line", 0),
							"kind": "scene_script",
							"target": node.script,
							"scene": path,
							"source": node_path,
							"status": "resolved"
						}
					)
					if not bindings.has(node.script):
						bindings[node.script] = []
					bindings[node.script].append({"scene": path, "node": node_path})
					if node.script.get_extension() == "gd" and not script_paths.has(node.script):
						if scope.include_addons or not node.script.begins_with("res://addons/"):
							script_paths.append(node.script)
	script_paths.sort()
	for path in script_paths:
		if FileAccess.open(path, FileAccess.READ) == null:
			return _error("Cannot read script: " + path)
		var scanned := ScriptAnalysis.scan(path)
		references.append_array(scanned.references)
		declarations.append_array(scanned.declarations)
	if kind == "script_references":
		return {
			"ok": true,
			"items": _page(references, body),
			"total": references.size(),
			"declarations": declarations,
			"unknown_count": _unknown(references),
			"runtime_complete": false,
			"limitations": LIMITATIONS,
			"scope": scope,
		}
	var edges: Array = scene_connections
	var signals: Array = []
	for declaration in declarations:
		if declaration.kind == "signal":
			declaration.merge({"source": "self", "method": "", "scene": ""})
			signals.append(declaration)
	for reference in references:
		if reference.kind in ["emit", "connect"]:
			var instances: Array = bindings.get(reference.path, [])
			if instances.is_empty():
				edges.append(reference)
			for binding in instances:
				var edge: Dictionary = reference.duplicate(true)
				edge.scene = binding.scene
				if edge.source == "self":
					edge.source = binding.node
				if edge.target == "self":
					edge.target = binding.node
				edges.append(edge)
	return {
		"ok": true,
		"items": _page(edges, body),
		"total": edges.size(),
		"signals": signals,
		"unknown_count": _unknown(edges),
		"runtime_complete": false,
		"limitations": LIMITATIONS,
		"scope": scope,
	}


static func _statistics(files: Array, scope: Dictionary) -> Dictionary:
	var bytes := 0
	var scripts := 0
	var scenes := 0
	var resources := 0
	var types: Dictionary = {}
	var extensions: Dictionary = {}
	for path in files:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return _error("Cannot read file: " + path)
		bytes += file.get_length()
		var extension: String = path.get_extension().to_lower()
		extensions[extension] = int(extensions.get(extension, 0)) + 1
		if extension == "gd":
			scripts += 1
		if extension in ["tscn", "scn"]:
			scenes += 1
		var type := ResourceLoader.get_resource_type(path)
		if not type.is_empty():
			resources += 1
			types[type] = int(types.get(type, 0)) + 1
	return {
		"ok": true,
		"file_count": files.size(),
		"bytes": bytes,
		"script_count": scripts,
		"scene_count": scenes,
		"resource_count": resources,
		"type_counts": types,
		"extension_counts": extensions,
		"scope": scope,
		"count_semantics":
		"ResourceLoader-recognized resources include scripts and scenes; "
		+ "bytes include all selected source files, not import-cache outputs."
	}


static func _complexity(files: Array, body: Dictionary, scope: Dictionary) -> Dictionary:
	var thresholds = body.get("thresholds", {})
	if not thresholds is Dictionary:
		return {"ok": false, "code": "invalid_param", "error": "thresholds must be a dictionary"}
	for key in thresholds:
		if (
			(
				key
				not in [
					"node_count",
					"max_depth",
					"script_count",
					"resource_reference_count",
					"connection_count"
				]
			)
			or not (thresholds[key] is int or thresholds[key] is float)
			or thresholds[key] < 0
		):
			return {
				"ok": false,
				"code": "invalid_param",
				"error": "thresholds require known metrics and nonnegative numbers"
			}
	var items: Array = []
	for path in files:
		if path.get_extension().to_lower() not in ["tscn", "scn"]:
			continue
		var scene := _scene(path)
		if not scene.ok:
			return scene
		var types: Dictionary = {}
		var scripts := 0
		var depth := 0
		for node_path in scene.nodes:
			var node: Dictionary = scene.nodes[node_path]
			var type := String(node.get("type", "Unknown"))
			types[type] = int(types.get(type, 0)) + 1
			if not String(node.get("script", "")).is_empty():
				scripts += 1
			depth = maxi(depth, 0 if node_path == "." else String(node_path).split("/").size())
		var item := {
			"path": path,
			"node_count": scene.nodes.size(),
			"max_depth": depth,
			"type_counts": types,
			"script_count": scripts,
			"resource_reference_count": scene.resources.size(),
			"resource_references": scene.resources,
			"connection_count": scene.connections.size(),
			"exceeded": []
		}
		for key in thresholds:
			if item[key] > thresholds[key]:
				item.exceeded.append(
					{"metric": key, "actual": item[key], "threshold": thresholds[key]}
				)
		item["within_thresholds"] = item.exceeded.is_empty()
		items.append(item)
	return {
		"ok": true,
		"items": _page(items, body),
		"total": items.size(),
		"scope": scope,
		"count_semantics":
		"Expanded SceneState nodes (instances and inheritance), root depth 0; "
		+ "scripts count attached nodes; resources are unique external and built-in resources, "
		+ "including recursive scene dependencies; connections are serialized connections only."
	}


static func _scene(path: String) -> Dictionary:
	var packed = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if not packed is PackedScene:
		return _error("Cannot load PackedScene: " + path)
	var out := {"ok": true, "nodes": {}, "connections": [], "resources": []}
	var expanded := _expand(packed.get_state(), path, ".", out, [])
	if not expanded.ok:
		return expanded
	out.resources.sort()
	return out


static func _expand(
	state: SceneState, scene: String, prefix: String, out: Dictionary, stack: Array
) -> Dictionary:
	if stack.has(state):
		return _error("Recursive scene state: " + scene)
	var ancestors := stack.duplicate()
	ancestors.append(state)
	var base := state.get_base_scene_state()
	if base != null:
		var base_path := base.get_path()
		var base_result := _expand(base, base_path, prefix, out, ancestors)
		if not base_result.ok:
			return base_result
	_collect_dependencies(scene, out.resources, {})
	var lines := _script_lines(scene)
	for i in range(state.get_node_count()):
		var relative := String(state.get_node_path(i)).trim_prefix("./")
		var node_path := _join(prefix, relative)
		var instance := state.get_node_instance(i)
		var placeholder := state.get_node_instance_placeholder(i)
		if not placeholder.is_empty():
			instance = (
				ResourceLoader.load(
					placeholder, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP
				)
				as PackedScene
			)
			if not instance is PackedScene:
				return _error("Cannot load scene placeholder: " + placeholder)
		if instance != null and not (base != null and relative == "."):
			var result := _expand(
				instance.get_state(), instance.resource_path, node_path, out, ancestors
			)
			if not result.ok:
				return result
		var node: Dictionary = out.nodes.get(node_path, {})
		var type := String(state.get_node_type(i))
		if not type.is_empty():
			node["type"] = type
		for property_index in range(state.get_node_property_count(i)):
			var name := String(state.get_node_property_name(i, property_index))
			var value = state.get_node_property_value(i, property_index)
			_collect_resources(value, scene, out.resources, {})
			if name == "script":
				node["script"] = value.resource_path if value is Script else ""
				node["origin"] = scene
				node["script_line"] = int(lines.get(relative, 0))
		out.nodes[node_path] = node
	for i in range(state.get_connection_count()):
		var connection := {
			"kind": "scene_connection",
			"path": scene,
			"line": 0,
			"scene": scene,
			"source": _join(prefix, String(state.get_connection_source(i))),
			"signal": String(state.get_connection_signal(i)),
			"target": _join(prefix, String(state.get_connection_target(i))),
			"method": String(state.get_connection_method(i)),
			"flags": state.get_connection_flags(i),
			"status": "resolved",
			"resolution": "serialized SceneState endpoints; callable validity is not asserted"
		}
		if not out.connections.has(connection):
			out.connections.append(connection)
	return {"ok": true}


static func _collect_resources(
	value: Variant, scene: String, resources: Array, visited: Dictionary
) -> void:
	if value is Resource:
		var identity := value.get_instance_id()
		if visited.has(identity):
			return
		visited[identity] = true
		var path := String(value.resource_path)
		if path.is_empty():
			path = scene + "::<builtin:" + str(identity) + ">"
		if not resources.has(path):
			resources.append(path)
		for property in value.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE:
				_collect_resources(value.get(property.name), scene, resources, visited)
	elif value is Array:
		for item in value:
			_collect_resources(item, scene, resources, visited)
	elif value is Dictionary:
		for key in value:
			_collect_resources(key, scene, resources, visited)
			_collect_resources(value[key], scene, resources, visited)


static func _collect_dependencies(path: String, resources: Array, visited: Dictionary) -> void:
	if path.is_empty() or visited.has(path):
		return
	visited[path] = true
	for dependency in ResourceLoader.get_dependencies(path):
		var pieces := String(dependency).split("::")
		var target := String(pieces[pieces.size() - 1])
		if target.begins_with("uid://"):
			var id := ResourceUID.text_to_id(target)
			if ResourceUID.has_id(id):
				target = ResourceUID.get_id_path(id)
		if not resources.has(target):
			resources.append(target)
		if ResourceLoader.exists(target):
			_collect_dependencies(target, resources, visited)


static func _script_lines(path: String) -> Dictionary:
	var result: Dictionary = {}
	if path.get_extension().to_lower() != "tscn":
		return result
	var name_regex := RegEx.new()
	name_regex.compile('name="([^"]+)"')
	var parent_regex := RegEx.new()
	parent_regex.compile('parent="([^"]+)"')
	var node := ""
	var lines := FileAccess.get_file_as_string(path).split("\n")
	for i in range(lines.size()):
		var line := String(lines[i]).strip_edges()
		if line.begins_with("[node "):
			var name_match := name_regex.search(line)
			var parent_match := parent_regex.search(line)
			if parent_match == null:
				node = "."
			elif name_match != null:
				node = _join(parent_match.get_string(1), name_match.get_string(1))
		elif line.begins_with("["):
			node = ""
		elif not node.is_empty() and line.begins_with("script ="):
			result[node] = i + 1
	return result


static func _join(prefix: String, path: String) -> String:
	if path == "." or path.is_empty():
		return prefix
	if prefix == "." or prefix.is_empty():
		return path.trim_prefix("./")
	return prefix + "/" + path.trim_prefix("./")


static func _unknown(items: Array) -> int:
	var count := 0
	for item in items:
		if item.get("status") == "unknown":
			count += 1
	return count


static func _page(items: Array, body: Dictionary) -> Array:
	var offset := maxi(0, int(body.get("offset", 0)))
	var limit := clampi(int(body.get("limit", 100)), 1, 500)
	return items.slice(offset, mini(items.size(), offset + limit))


static func _error(message: String) -> Dictionary:
	return {"ok": false, "code": "godot_error", "error": message}
