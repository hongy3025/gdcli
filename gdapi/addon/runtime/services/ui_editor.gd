@tool
class_name GdApiUiEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")


static func text_set(node_path: Variant, text: Variant) -> Dictionary:
	var found := _control(node_path)
	if not found.ok:
		return found
	if not (
		found.node is Button
		or found.node is Label
		or found.node is LineEdit
		or found.node is TextEdit
	):
		return _error(ErrorCodes.NOT_SUPPORTED, "control does not support text")
	if typeof(text) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "text must be a string")
	return _property(found.node, &"text", text, "gdcli: set UI text")


static func set_anchor(node_path: Variant, anchors: Variant, offsets: Variant = {}) -> Dictionary:
	var found := _control(node_path)
	if not found.ok:
		return found
	if typeof(anchors) != TYPE_DICTIONARY:
		return _error(ErrorCodes.INVALID_PARAM, "anchors must be an object")
	var manager := EditAction.undo_redo()
	if manager == null:
		return _error(ErrorCodes.NOT_SUPPORTED, "EditorUndoRedoManager unavailable")
	manager.create_action("gdcli: set UI anchors", UndoRedo.MERGE_DISABLE, found.node)
	var changed := false
	for key in ["left", "top", "right", "bottom"]:
		if anchors.has(key):
			if typeof(anchors[key]) != TYPE_FLOAT and typeof(anchors[key]) != TYPE_INT:
				return _error(ErrorCodes.INVALID_PARAM, "anchor values must be numbers")
			var property := StringName("anchor_" + key)
			manager.add_do_property(found.node, property, float(anchors[key]))
			manager.add_undo_property(found.node, property, found.node.get(property))
			changed = true
	for key in ["left", "top", "right", "bottom"]:
		if typeof(offsets) == TYPE_DICTIONARY and offsets.has(key):
			var property := StringName("offset_" + key)
			manager.add_do_property(found.node, property, float(offsets[key]))
			manager.add_undo_property(found.node, property, found.node.get(property))
			changed = true
	if not changed:
		return _error(ErrorCodes.INVALID_PARAM, "at least one anchor is required")
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true, "node_path": found.path}


static func build_layout(node_path: Variant, layout: Variant) -> Dictionary:
	if typeof(layout) != TYPE_STRING or layout not in ["full_rect", "center"]:
		return _error(ErrorCodes.INVALID_PARAM, "layout must be full_rect or center")
	var anchors: Dictionary = (
		{"left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0}
		if layout == "full_rect"
		else {"left": 0.5, "top": 0.5, "right": 0.5, "bottom": 0.5}
	)
	return set_anchor(node_path, anchors)


static func _control(node_path: Variant) -> Dictionary:
	if typeof(node_path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "node_path must be a string")
	var root := SceneEditor.current_root()
	if root == null:
		return _error(ErrorCodes.NOT_FOUND, "no scene is currently open")
	var node: Node = (
		root
		if String(node_path) == String(root.name)
		else root.get_node_or_null(NodePath(node_path))
	)
	if node == null:
		return _error(ErrorCodes.NOT_FOUND, "control not found")
	if not node is Control:
		return _error(ErrorCodes.NOT_SUPPORTED, "node must be Control")
	return {"ok": true, "node": node, "path": String(node_path)}


static func _property(
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


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
