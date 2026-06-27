@tool
class_name GdApiEditAction
extends RefCounted

static func plugin():
	if Engine.has_meta("gdapi_plugin"):
		return Engine.get_meta("gdapi_plugin")
	return null

static func undo_redo():
	var p = plugin()
	if p and p.has_method("get_undo_redo"):
		return p.get_undo_redo()
	return null

static func has_undo_redo() -> bool:
	return undo_redo() != null
