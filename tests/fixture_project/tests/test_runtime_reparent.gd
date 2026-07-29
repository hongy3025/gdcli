## GdApiRuntimeNodeOps reparent safety closure tests.
@tool
extends SceneTree

const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")

var passed := 0
var failed := 0
var scene: Node
var parent_node: Node
var child_node: Node

func _init() -> void:
	print("Running GdApiRuntimeNodeOps reparent closure tests...\n")
	call_deferred("_run")

func _run() -> void:
	_setup_tree()
	await process_frame
	test_reparent_rejects_self_without_mutation()
	test_reparent_rejects_descendant_without_mutation()
	test_reparent_rejects_scene_root_without_mutation()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func _setup_tree() -> void:
	scene = Node.new()
	scene.name = "Task15Scene"
	root.add_child(scene)
	current_scene = scene
	parent_node = Node.new()
	parent_node.name = "Task15Parent"
	parent_node.set_meta("gdapi_runtime_dedicated", true)
	scene.add_child(parent_node)
	child_node = Node.new()
	child_node.name = "Task15Child"
	child_node.set_meta("gdapi_runtime_dedicated", true)
	parent_node.add_child(child_node)

func _assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func _assert_cycle_rejected(payload: Dictionary, context: String) -> void:
	var before_parent := String(parent_node.get_path())
	var before_child := String(child_node.get_path())
	var result := NodeOps.reparent(payload)
	_assert_eq(result.get("ok", true), false, context + " rejects mutation")
	_assert_eq(result.get("code", ""), "conflict", context + " reports conflict")
	_assert_eq(String(parent_node.get_path()), before_parent, context + " keeps parent path")
	_assert_eq(String(child_node.get_path()), before_child, context + " keeps child path")
	_assert_eq(child_node.get_parent(), parent_node, context + " keeps child parent")

func test_reparent_rejects_self_without_mutation() -> void:
	_assert_cycle_rejected({
		"node_path": String(child_node.get_path()),
		"new_parent": String(child_node.get_path()),
	}, "self reparent")

func test_reparent_rejects_descendant_without_mutation() -> void:
	_assert_cycle_rejected({
		"node_path": String(parent_node.get_path()),
		"new_parent": String(child_node.get_path()),
	}, "descendant reparent")

func test_reparent_rejects_scene_root_without_mutation() -> void:
	var before_parent := String(parent_node.get_path())
	var result := NodeOps.reparent({
		"node_path": String(scene.get_path()),
		"new_parent": String(parent_node.get_path()),
	})
	_assert_eq(result.get("ok", true), false, "scene root reparent rejects mutation")
	_assert_eq(result.get("code", ""), "permission_denied", "scene root reparent reports permission")
	_assert_eq(String(parent_node.get_path()), before_parent, "scene root rejection keeps fixture tree")
