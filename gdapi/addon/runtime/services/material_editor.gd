@tool
class_name GdApiMaterialEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const NodePathResolver := preload("res://addons/gdapi/runtime/services/node_path_resolver.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const EDITABLE_PROPERTIES := {
	"CanvasItemMaterial":
	{"blend_mode": TYPE_INT, "light_mode": TYPE_INT, "particles_animation": TYPE_BOOL},
	"StandardMaterial2D": {"albedo_color": TYPE_COLOR, "shading_mode": TYPE_INT},
}


static func create(node_path: Variant, type: Variant) -> Dictionary:
	var target := _node(node_path)
	if not target.ok:
		return target
	if typeof(type) != TYPE_STRING or not EDITABLE_PROPERTIES.has(type):
		return _error(ErrorCodes.INVALID_PARAM, "unsupported material type")
	var material: Material = ClassDB.instantiate(type)
	if material == null:
		return _error(ErrorCodes.GODOT_ERROR, "failed to instantiate material")
	return _commit_property(target.node, &"material", material, "gdcli: create material")


static func info(node_path: Variant) -> Dictionary:
	var material := _material(node_path)
	if not material.ok:
		return material
	var properties: Dictionary = {}
	for name in EDITABLE_PROPERTIES[material.material.get_class()]:
		properties[name] = VariantCodec.from_variant(material.material.get(name))
	return {
		"ok": true,
		"node_path": material.node_path,
		"class": material.material.get_class(),
		"path": material.material.resource_path,
		"properties": properties,
		"undoable": false,
	}


static func set_property(node_path: Variant, property: Variant, value: Variant) -> Dictionary:
	var material := _material(node_path)
	if not material.ok:
		return material
	if typeof(property) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "property must be a string")
	var allowed: Dictionary = EDITABLE_PROPERTIES[material.material.get_class()]
	if not allowed.has(property):
		return _error(
			ErrorCodes.NOT_FOUND, "material property is not editable: " + String(property)
		)
	var decoded := VariantCodec.decode(value)
	if not decoded.ok or not _matches_type(decoded.value, int(allowed[property])):
		return _error(ErrorCodes.INVALID_PARAM, "invalid value type for material property")
	if int(allowed[property]) == TYPE_INT and typeof(decoded.value) == TYPE_FLOAT:
		decoded.value = int(decoded.value)
	return _commit_property(
		material.material, StringName(property), decoded.value, "gdcli: set material property"
	)


static func assign(node_path: Variant, path: Variant) -> Dictionary:
	var target := _node(node_path)
	if not target.ok:
		return target
	var checked := _project_path(path, "read")
	if not checked.ok:
		return checked
	if not ResourceLoader.exists(checked.path):
		return _error(ErrorCodes.NOT_FOUND, "material resource not found")
	var resource := ResourceLoader.load(checked.path, "Material")
	if not resource is Material:
		return _error(ErrorCodes.INVALID_PARAM, "resource is not a Material")
	var result := _commit_property(target.node, &"material", resource, "gdcli: assign material")
	if result.ok:
		result["path"] = checked.path
	return result


static func save(node_path: Variant, path: Variant, route: String = "material/save") -> Dictionary:
	var material := _material(node_path)
	if not material.ok:
		return material
	return _save_resource(material.material, path, route)


static func duplicate_material(node_path: Variant, path: Variant) -> Dictionary:
	var material := _material(node_path)
	if not material.ok:
		return material
	var copy: Variant = material.material.duplicate(true)
	if not copy is Material:
		return _error(ErrorCodes.GODOT_ERROR, "material duplication failed")
	return _save_resource(copy, path, "material/duplicate")


## node_path 同时接受场景根相对路径与 node/* 回传的绝对用户路径。
static func _node(node_path: Variant) -> Dictionary:
	if typeof(node_path) != TYPE_STRING or String(node_path).strip_edges().is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "node_path is required")
	var found := NodePathResolver.resolve(node_path)
	if not found.ok:
		return _error(found.code, found.error)
	var node: Node = found.node
	if not ("material" in node):
		return _error(ErrorCodes.NOT_FOUND, "node with material property not found")
	return {"ok": true, "node": node, "node_path": found.path}


static func _material(node_path: Variant) -> Dictionary:
	var target := _node(node_path)
	if not target.ok:
		return target
	var material = target.node.get("material")
	if not material is Material:
		return _error(ErrorCodes.NOT_FOUND, "node has no material")
	if not EDITABLE_PROPERTIES.has(material.get_class()):
		return _error(
			ErrorCodes.NOT_SUPPORTED, "material type is not supported: " + material.get_class()
		)
	return {"ok": true, "node": target.node, "node_path": target.node_path, "material": material}


static func _commit_property(
	target: Object, property: StringName, value: Variant, action: String
) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	var previous := target.get(property)
	manager.create_action(action, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_property(target, property, value)
	manager.add_undo_property(target, property, previous)
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true}


static func _matches_type(value: Variant, expected: int) -> bool:
	if expected == TYPE_INT and (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT):
		return true
	return typeof(value) == expected


static func _save_resource(resource: Material, path: Variant, route: String) -> Dictionary:
	var checked := _project_path(path, "write")
	if not checked.ok:
		AuditLog.record(route, "file", {"path": path}, false, checked.code)
		return checked
	return ResourceEditor.save_verified(resource, checked.path, route)


static func _project_path(path: Variant, mode: String) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "path must be a string")
	var checked := PathGuard.validate(path, mode)
	if not checked.ok:
		return _error(checked.code, checked.error)
	if not String(checked.path).begins_with("res://"):
		return _error(ErrorCodes.INVALID_PATH, "only project-local res:// paths are allowed")
	if not (String(checked.path).ends_with(".tres") or String(checked.path).ends_with(".res")):
		return _error(ErrorCodes.INVALID_PATH, "material path must end in .tres or .res")
	return {"ok": true, "path": checked.path}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
