@tool
extends SceneTree

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

var passed := 0
var failed := 0


func _init() -> void:
	var empty_root := Node.new()
	empty_root.scene_file_path = ""
	var dirty_root := Node.new()
	dirty_root.scene_file_path = "res://scenes/save_as_target.tscn"
	var roots: Array = [empty_root, dirty_root]
	var open_paths := PackedStringArray(["", "res://scenes/original.tscn"])
	var unsaved_paths := PackedStringArray(["res://scenes/original.tscn"])

	assert_eq(
		SceneEditor._root_tab_is_unsaved(dirty_root, roots, open_paths, unsaved_paths),
		true,
		"dirty tab is found after an empty-path tab"
	)
	assert_eq(
		SceneEditor._scene_tab_status_for(
			"res://scenes/save_as_target.tscn", roots, open_paths, unsaved_paths
		),
		{"open": true, "unsaved": true},
		"save-as root path matches dirty status at its editor index"
	)
	assert_eq(
		SceneEditor._scene_tab_status_for("", roots, open_paths, unsaved_paths),
		{"open": true, "unsaved": false},
		"empty-path root remains distinct from the following dirty tab"
	)
	var roots_without_empty_root: Array = [dirty_root]
	assert_eq(
		SceneEditor._root_tab_is_unsaved(
			dirty_root, roots_without_empty_root, open_paths, unsaved_paths
		),
		true,
		"rootless empty tab is skipped when roots array omits null entries"
	)
	assert_eq(
		SceneEditor._scene_tab_status_for(
			"res://scenes/save_as_target.tscn", roots_without_empty_root, open_paths, unsaved_paths
		),
		{"open": true, "unsaved": true},
		"scene status maps past the rootless empty tab"
	)
	empty_root.free()
	dirty_root.free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
