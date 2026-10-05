@tool
class_name GdApiPhysicsEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const NodePathResolver := preload("res://addons/gdapi/runtime/services/node_path_resolver.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")


static func create_body(parent_path: Variant, name: Variant, type: Variant) -> Dictionary:
	if (
		typeof(type) != TYPE_STRING
		or type not in ["StaticBody2D", "RigidBody2D", "CharacterBody2D", "AnimatableBody2D"]
	):
		return _error(ErrorCodes.NOT_SUPPORTED, "only supported 2D physics bodies are allowed")
	if typeof(name) != TYPE_STRING or String(name).is_empty():
		return _error(ErrorCodes.MISSING_PARAM, "name is required")
	return NodeEditor.create_node(_absolute(parent_path), String(type), String(name))


static func create_shape(body_path: Variant, shape: Variant, size: Variant) -> Dictionary:
	if typeof(shape) != TYPE_STRING or shape not in ["rectangle", "circle", "capsule"]:
		return _error(ErrorCodes.INVALID_PARAM, "unsupported 2D shape")
	var created := NodeEditor.create_node(
		_absolute(body_path), "CollisionShape2D", "CollisionShape2D"
	)
	if not created.ok:
		return created
	var node := _find(String(body_path) + "/" + String(created.name))
	if not node.ok:
		return node
	var resource: Shape2D
	if shape == "rectangle":
		var rect := RectangleShape2D.new()
		var decoded := VariantCodec.decode(size)
		if not decoded.ok:
			return _error(ErrorCodes.INVALID_PARAM, decoded.error)
		if decoded.value is Vector2:
			rect.size = decoded.value
		elif typeof(size) == TYPE_DICTIONARY and size.has("x") and size.has("y"):
			rect.size = Vector2(float(size.x), float(size.y))
		else:
			return _error(ErrorCodes.INVALID_PARAM, "rectangle size must be Vector2")
		resource = rect
	elif shape == "circle":
		var circle := CircleShape2D.new()
		circle.radius = float(size)
		resource = circle
	else:
		var capsule := CapsuleShape2D.new()
		capsule.radius = 4.0
		capsule.height = float(size)
		resource = capsule
	var result := _set_property(node.node, &"shape", resource, "gdcli: create physics shape")
	result["node_path"] = node.path
	return result


static func set_layer(node_path: Variant, property: Variant, value: Variant) -> Dictionary:
	if property not in ["collision_layer", "collision_mask"]:
		return _error(ErrorCodes.INVALID_PARAM, "invalid collision property")
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return _error(ErrorCodes.INVALID_PARAM, "layer value must be an integer")
	var number := int(value)
	if number < 1 or number > 4294967295:
		return _error(ErrorCodes.INVALID_PARAM, "layer value out of range")
	var found := _find(String(node_path))
	if not found.ok:
		return found
	return _set_property(found.node, StringName(property), number, "gdcli: set collision layer")


static func create_joint(parent_path: Variant, type: Variant, name: Variant) -> Dictionary:
	if type not in ["PinJoint2D", "DampedSpringJoint2D", "GrooveJoint2D"]:
		return _error(ErrorCodes.NOT_SUPPORTED, "unsupported 2D joint")
	return NodeEditor.create_node(_absolute(parent_path), String(type), String(name))


static func _set_property(
	node: Object, property: StringName, value: Variant, action: String
) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	manager.create_action(action, UndoRedo.MERGE_DISABLE, node)
	manager.add_do_property(node, property, value)
	manager.add_undo_property(node, property, node.get(property))
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true}


## node_path/body_path/parent_path 同时接受场景根相对路径与 node/* 回传的绝对用户路径。
static func _find(path: String) -> Dictionary:
	var found := NodePathResolver.resolve(path)
	if not found.ok:
		return _error(found.code, found.error)
	return {"ok": true, "node": found.node, "path": found.path}


static func _absolute(path: Variant) -> String:
	var found := NodePathResolver.resolve(path if typeof(path) == TYPE_STRING else "")
	if found.ok:
		return found.path
	return String(path) if typeof(path) == TYPE_STRING else ""


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
