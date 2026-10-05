@tool
extends RefCounted

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

const OWNED_SCENE := "res://.godot/tab_marker_owned_%d.tscn"
const FRAME_LIMIT := 240

var passed := 0
var failed := 0


func run(tree: SceneTree) -> Dictionary:
	test_unsaved_path_decode_resolves_duplicates()
	await test_live_dirty_marker_tracks_real_edit_and_save(tree)
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


## get_unsaved_scenes() 是按 tab 顺序过滤出的有序子序列。
func test_unsaved_path_decode_resolves_duplicates() -> void:
	var paths := PackedStringArray(
		[
			"res://scenes/runtime_main.tscn",
			"res://scenes/main.tscn",
			"res://scenes/main.tscn",
		]
	)
	assert_eq(
		SceneEditor._unsaved_indexes(paths, PackedStringArray(["res://scenes/main.tscn"])),
		{1: true},
		"duplicate registered path flags only the matching tab"
	)
	assert_eq(
		SceneEditor._unsaved_indexes(
			paths, PackedStringArray(["res://scenes/main.tscn", "res://scenes/main.tscn"])
		),
		{1: true, 2: true},
		"both duplicated tabs flagged when both are dirty"
	)
	assert_eq(
		SceneEditor._unsaved_indexes(
			PackedStringArray(["", "res://scenes/main.tscn", ""]),
			PackedStringArray(["res://scenes/main.tscn"])
		),
		{1: true},
		"empty-path tabs keep the index mapping"
	)
	assert_true(
		SceneEditor._tab_unsaved_flags() is Dictionary,
		"live scene tab markers are reachable in this editor"
	)
	assert_eq(
		SceneEditor._open_path_index_for_root(
			0,
			[_root_for("res://scenes/main.tscn")],
			PackedStringArray(["", "res://scenes/main.tscn"])
		),
		1,
		"rootless tabs still map to the following editor index"
	)


## 真实 dirty 标记只存在于场景 tab 标题（"(*)"）；用自己拥有的场景验证完整闭环。
func test_live_dirty_marker_tracks_real_edit_and_save(tree: SceneTree) -> void:
	var path := OWNED_SCENE % Time.get_ticks_usec()
	var previous_path := SceneEditor.current_path()
	var packed := PackedScene.new()
	var owned_root := Node2D.new()
	owned_root.name = "TabMarkerOwned"
	var pack_error := packed.pack(owned_root)
	owned_root.free()
	assert_eq(pack_error, OK, "owned scene packs")
	if pack_error != OK:
		return
	assert_eq(ResourceSaver.save(packed, path), OK, "owned scene is saved")
	EditorInterface.open_scene_from_path(path)
	if not await _wait_for_current(tree, path):
		assert_true(false, "owned scene becomes the current tab")
		_remove_owned(path)
		return
	assert_eq(
		SceneEditor._scene_tab_status(path),
		{"open": true, "unsaved": false},
		"freshly opened owned tab is clean"
	)
	var manager := EditAction.undo_redo()
	var edited_root := EditorInterface.get_edited_scene_root()
	manager.create_action("tab marker edit", UndoRedo.MERGE_DISABLE, edited_root)
	manager.add_do_property(edited_root, "position", Vector2(3, 4))
	manager.commit_action()
	assert_true(await _wait_for_marker(tree, path, true), "real edit marks the owned tab dirty")
	assert_eq(SceneEditor.is_current_scene_unsaved(), true, "current scene reports the edit")
	assert_eq(EditorInterface.save_scene(), OK, "owned tab saves")
	assert_true(await _wait_for_marker(tree, path, false), "save clears the owned tab marker")
	assert_eq(SceneEditor.is_current_scene_unsaved(), false, "current scene reports the save")
	if SceneEditor.current_path() == path:
		EditorInterface.close_scene()
	if not previous_path.is_empty():
		EditorInterface.open_scene_from_path(previous_path)
		assert_true(await _wait_for_current(tree, previous_path), "previous scene is restored")
	_remove_owned(path)


func _wait_for_current(tree: SceneTree, path: String) -> bool:
	for _frame in FRAME_LIMIT:
		if SceneEditor.current_path() == path:
			return true
		await tree.process_frame
	return false


## 场景 tab 标题在编辑器下一帧刷新，等它稳定后再断言。
func _wait_for_marker(tree: SceneTree, path: String, unsaved: bool) -> bool:
	for _frame in FRAME_LIMIT:
		if SceneEditor._scene_tab_status(path).unsaved == unsaved:
			return true
		await tree.process_frame
	return false


func _remove_owned(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _root_for(path: String) -> Node:
	var root := Node2D.new()
	root.scene_file_path = path
	return root


func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])
