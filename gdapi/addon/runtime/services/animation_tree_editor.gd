@tool
class_name GdApiAnimationTreeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

static func tree(path: String) -> Dictionary:
	var root := SceneEditor.current_root()
	if root == null: return {"ok":false,"code":ErrorCodes.NOT_FOUND,"error":"no scene is currently open"}
	var node := root.get_node_or_null(NodePath(path))
	if not node is AnimationTree: return {"ok":false,"code":ErrorCodes.NOT_FOUND,"error":"AnimationTree not found"}
	return {"ok":true,"tree":node}

static func set_blend(path: String, parameter: String, value: Variant) -> Dictionary:
	if not parameter.begins_with("parameters/") or not parameter.ends_with("/blend_position"):
		return {"ok":false,"code":ErrorCodes.INVALID_PARAM,"error":"parameter must be a blend_position path"}
	var found := tree(path)
	if not found.ok: return found
	var state_name := parameter.trim_prefix("parameters/").trim_suffix("/blend_position")
	if state_name.is_empty() or "/" in state_name:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "parameter must address one direct state-machine node"}
	var machine = found.tree.tree_root
	if not machine is AnimationNodeStateMachine or not machine.has_node(StringName(state_name)):
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "blend state not found"}
	var blend_node = machine.get_node(StringName(state_name))
	if not (blend_node is AnimationNodeBlendSpace1D or blend_node is AnimationNodeBlendSpace2D):
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "state must be an AnimationNodeBlendSpace"}
	var result := EditAction.commit_property(found.tree, StringName(parameter), value, "gdcli: set animation blend")
	if not result.ok: return {"ok":false,"code":ErrorCodes.NOT_SUPPORTED,"error":result.error}
	return {"ok":true,"changed":true,"undoable":true,"parameter":parameter}

static func add_state(path: String, name: String) -> Dictionary:
	if name.is_empty():
		return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "name is required"}
	return _mutate_state_machine(path, "gdcli: add animation tree state", func(machine: AnimationNodeStateMachine) -> Dictionary:
		if machine.has_node(StringName(name)):
			return {"ok": false, "code": ErrorCodes.CONFLICT, "error": "state already exists"}
		machine.add_node(StringName(name), AnimationNodeAnimation.new(), Vector2.ZERO)
		return {"ok": true, "name": name}
	)

static func add_transition(path: String, from: String, to: String) -> Dictionary:
	if from.is_empty() or to.is_empty():
		return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "from and to are required"}
	return _mutate_state_machine(path, "gdcli: add animation tree transition", func(machine: AnimationNodeStateMachine) -> Dictionary:
		if not machine.has_node(StringName(from)) or not machine.has_node(StringName(to)):
			return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "state not found"}
		machine.add_transition(StringName(from), StringName(to), AnimationNodeStateMachineTransition.new())
		return {"ok": true, "from": from, "to": to}
	)

static func _mutate_state_machine(path: String, action: String, callback: Callable) -> Dictionary:
	var found := tree(path)
	if not found.ok:
		return found
	var before = found.tree.tree_root
	if not before is AnimationNodeStateMachine:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "AnimationTree tree_root must be AnimationNodeStateMachine"}
	var after: AnimationNodeStateMachine = before.duplicate(true)
	var verdict: Dictionary = callback.call(after)
	if not verdict.ok:
		return verdict
	var result := EditAction.commit_property(found.tree, &"tree_root", after, action)
	if not result.ok:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": result.error}
	return {"ok": true, "changed": true, "undoable": true}.merged(verdict)
