@tool
class_name GdApiEditAction
extends RefCounted

static func plugin() -> Object:
	if Engine.has_meta("gdapi_plugin"):
		return Engine.get_meta("gdapi_plugin")
	return null

static func undo_redo() -> EditorUndoRedoManager:
	var p := plugin()
	if p and p.has_method("get_undo_redo"):
		var manager = p.get_undo_redo()
		if manager is EditorUndoRedoManager:
			return manager
	return null

static func has_undo_redo() -> bool:
	return undo_redo() != null

## 通过 EditorUndoRedoManager 提交属性变更
##
## 创建 undo/redo action，设置目标对象的属性值。
## @param target 目标对象
## @param property 属性名
## @param value 新值
## @param action_name undo/redo 操作名称
## @return {ok:true, previous:Variant, history_id:int} 或 {ok:false, error:String}
static func commit_property(
	target: Object,
	property: StringName,
	value: Variant,
	action_name: String
) -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {"ok": false, "error": "target is invalid"}
	var manager = undo_redo()
	if manager == null:
		return {"ok": false, "error": "EditorUndoRedoManager is unavailable"}
	var previous = target.get(property)
	manager.create_action(action_name, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_property(target, property, value)
	manager.add_undo_property(target, property, previous)
	manager.commit_action()
	return {
		"ok": true,
		"previous": previous,
		"history_id": manager.get_object_history_id(target),
	}
