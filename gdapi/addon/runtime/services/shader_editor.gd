@tool
class_name GdApiShaderEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")


static func read(path: Variant) -> Dictionary:
	var checked := _shader_path(path, "read")
	if not checked.ok:
		return checked
	if not FileAccess.file_exists(checked.path):
		return _error(ErrorCodes.NOT_FOUND, "shader not found")
	return {
		"ok": true,
		"path": checked.path,
		"source": FileAccess.get_file_as_string(checked.path),
		"undoable": false
	}


static func write(path: Variant, source: Variant, force: Variant) -> Dictionary:
	var checked := _shader_path(path, "write")
	if not checked.ok:
		AuditLog.record("shader/write", "file", {"path": path}, false, checked.code)
		return checked
	if typeof(source) != TYPE_STRING or not String(source).contains("shader_type"):
		AuditLog.record(
			"shader/write", "file", {"path": checked.path}, false, ErrorCodes.INVALID_PARAM
		)
		return _error(
			ErrorCodes.INVALID_PARAM, "source must be shader source containing shader_type"
		)
	if typeof(force) != TYPE_BOOL:
		AuditLog.record(
			"shader/write", "file", {"path": checked.path}, false, ErrorCodes.INVALID_PARAM
		)
		return _error(ErrorCodes.INVALID_PARAM, "force must be a bool")
	if FileAccess.file_exists(checked.path) and not force:
		AuditLog.record(
			"shader/write",
			"file",
			{"path": checked.path, "force": false},
			false,
			ErrorCodes.UNSAFE_OPERATION
		)
		return _error(
			ErrorCodes.UNSAFE_OPERATION, "shader/write requires force:true for an existing target"
		)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(checked.path).get_base_dir()
	)
	var file := FileAccess.open(checked.path, FileAccess.WRITE)
	if file == null:
		AuditLog.record(
			"shader/write", "file", {"path": checked.path}, false, ErrorCodes.GODOT_ERROR
		)
		return _error(ErrorCodes.GODOT_ERROR, "failed to open shader for writing")
	file.store_string(source)
	file.close()
	AuditLog.record(
		"shader/write",
		"file",
		{"path": checked.path, "bytes": String(source).length(), "force": force},
		true
	)
	return {
		"ok": true,
		"changed": true,
		"written": true,
		"undoable": false,
		"path": checked.path,
		"bytes": String(source).length()
	}


static func uniforms(path: Variant) -> Dictionary:
	var source := read(path)
	if not source.ok:
		return source
	return {
		"ok": true,
		"path": source.path,
		"uniforms": parse_uniforms(source.source),
		"undoable": false
	}


static func create_material(shader_path: Variant, path: Variant, force: Variant) -> Dictionary:
	var shader_checked := _shader_path(shader_path, "read")
	if not shader_checked.ok:
		return shader_checked
	if not ResourceLoader.exists(shader_checked.path):
		return _error(ErrorCodes.NOT_FOUND, "shader not found")
	var shader := ResourceLoader.load(
		shader_checked.path, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	)
	if not shader is Shader:
		return _error(ErrorCodes.GODOT_ERROR, "failed to load shader")
	var material := ShaderMaterial.new()
	material.shader = shader
	return _save_material(material, path, force, "shader/material/create")


static func set_param(path: Variant, name: Variant, value: Variant, force: Variant) -> Dictionary:
	var checked := _material_path(path, "write")
	if not checked.ok:
		AuditLog.record("shader/param/set", "file", {"path": path}, false, checked.code)
		return checked
	if typeof(name) != TYPE_STRING or String(name).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	if not FileAccess.file_exists(checked.path):
		return _error(ErrorCodes.NOT_FOUND, "shader material not found")
	if typeof(force) != TYPE_BOOL:
		return _error(ErrorCodes.INVALID_PARAM, "force must be a bool")
	if not force:
		AuditLog.record(
			"shader/param/set",
			"file",
			{"path": checked.path, "force": false},
			false,
			ErrorCodes.UNSAFE_OPERATION
		)
		return _error(ErrorCodes.UNSAFE_OPERATION, "shader/param/set requires force:true")
	var material := ResourceLoader.load(
		checked.path, "ShaderMaterial", ResourceLoader.CACHE_MODE_IGNORE
	)
	if not material is ShaderMaterial or material.shader == null:
		return _error(ErrorCodes.INVALID_PARAM, "resource is not a ShaderMaterial with a shader")
	var specification := _uniform(material.shader, String(name))
	if specification.is_empty():
		return _error(ErrorCodes.NOT_FOUND, "shader uniform not found: " + String(name))
	var decoded := _decode_uniform_value(value, specification.type)
	if not decoded.ok:
		return decoded
	material.set_shader_parameter(String(name), decoded.value)
	var saved := ResourceSaver.save(material, checked.path)
	if saved != OK:
		AuditLog.record(
			"shader/param/set",
			"file",
			{"path": checked.path, "name": name},
			false,
			ErrorCodes.GODOT_ERROR
		)
		return _error(ErrorCodes.GODOT_ERROR, "ResourceSaver.save failed: " + str(saved))
	AuditLog.record("shader/param/set", "file", {"path": checked.path, "name": name}, true)
	return {
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": checked.path,
		"name": String(name)
	}


static func parse_uniforms(source: String) -> Array:
	var regex := RegEx.new()
	regex.compile(
		(
			"^\\s*uniform\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+([A-Za-z_][A-Za-z0-9_]*)"
			+ "\\s*(?::[^=;]+)?(?:=\\s*([^;]+))?\\s*;"
		)
	)
	var result: Array = []
	for line in source.split("\n"):
		var match := regex.search(line)
		if match != null:
			result.append(
				{
					"name": match.get_string(2),
					"type": match.get_string(1),
					"default": match.get_string(3).strip_edges()
				}
			)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.name < b.name)
	return result


static func _uniform(shader: Shader, name: String) -> Dictionary:
	var path := shader.resource_path
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	for item in parse_uniforms(FileAccess.get_file_as_string(path)):
		if item.name == name:
			return item
	return {}


static func _decode_uniform_value(value: Variant, type: String) -> Dictionary:
	var decoded := VariantCodec.decode(value)
	if not decoded.ok:
		return _error(ErrorCodes.INVALID_PARAM, decoded.error)
	var expected := {
		"float": TYPE_FLOAT,
		"int": TYPE_INT,
		"bool": TYPE_BOOL,
		"vec2": TYPE_VECTOR2,
		"vec3": TYPE_VECTOR3,
		"vec4": TYPE_COLOR
	}
	if not expected.has(type) or typeof(decoded.value) != int(expected[type]):
		return _error(ErrorCodes.INVALID_PARAM, "invalid value type for shader uniform " + type)
	return {"ok": true, "value": decoded.value}


static func _save_material(
	material: ShaderMaterial, path: Variant, force: Variant, route: String
) -> Dictionary:
	var checked := _material_path(path, "write")
	if not checked.ok:
		AuditLog.record(route, "file", {"path": path}, false, checked.code)
		return checked
	if typeof(force) != TYPE_BOOL:
		return _error(ErrorCodes.INVALID_PARAM, "force must be a bool")
	if FileAccess.file_exists(checked.path) and not force:
		AuditLog.record(
			route,
			"file",
			{"path": checked.path, "force": false},
			false,
			ErrorCodes.UNSAFE_OPERATION
		)
		return _error(
			ErrorCodes.UNSAFE_OPERATION, route + " requires force:true for an existing target"
		)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(checked.path).get_base_dir()
	)
	var saved := ResourceSaver.save(material, checked.path)
	if saved != OK:
		AuditLog.record(route, "file", {"path": checked.path}, false, ErrorCodes.GODOT_ERROR)
		return _error(ErrorCodes.GODOT_ERROR, "ResourceSaver.save failed: " + str(saved))
	AuditLog.record(route, "file", {"path": checked.path, "force": force}, true)
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": checked.path}


static func _shader_path(path: Variant, mode: String) -> Dictionary:
	var checked := _path(path, mode)
	if not checked.ok:
		return checked
	if not String(checked.path).ends_with(".gdshader"):
		return _error(ErrorCodes.INVALID_PATH, "shader path must end in .gdshader")
	return checked


static func _material_path(path: Variant, mode: String) -> Dictionary:
	var checked := _path(path, mode)
	if not checked.ok:
		return checked
	if not (String(checked.path).ends_with(".tres") or String(checked.path).ends_with(".res")):
		return _error(ErrorCodes.INVALID_PATH, "shader material path must end in .tres or .res")
	return checked


static func _path(path: Variant, mode: String) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "path must be a string")
	var checked := PathGuard.validate(path, mode)
	if not checked.ok:
		return _error(checked.code, checked.error)
	if not String(checked.path).begins_with("res://"):
		return _error(ErrorCodes.INVALID_PATH, "only project-local res:// paths are allowed")
	return {"ok": true, "path": checked.path}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
