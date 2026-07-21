@tool
extends EditorPlugin

const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

func _enter_tree() -> void:
	if OS.get_environment("GDAPI_RUN_EDITOR_TESTS") == "1":
		_run.call_deferred()

func _run() -> void:
	EditorInterface.open_scene_from_path("res://test.tscn")
	for _i in range(5):
		await get_tree().process_frame
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_fail("edited scene root is null")
		return
	var original: Vector2 = root.position
	var changed := Vector2(41, 73)
	var result := EditAction.commit_property(root, &"position", changed, "gdapi test position")
	if not result.ok or root.position != changed:
		_fail("commit_property did not apply value")
		return
	var manager := get_undo_redo()
	var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not history.undo() or root.position != original:
		_fail("undo did not restore value")
		return
	if not history.redo() or root.position != changed:
		_fail("redo did not restore changed value")
		return
	print("GDAPI_EDITOR_TEST_PASS")
	get_tree().quit(0)

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)