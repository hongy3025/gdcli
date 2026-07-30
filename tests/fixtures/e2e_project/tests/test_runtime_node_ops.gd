## GdApiRuntimeNodeOps dedicated-node safety tests.

@tool
extends SceneTree

const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")

var passed := 0
var failed := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := Node2D.new()
	scene.name = "Task9Scene"
	root.add_child(scene)
	current_scene = scene

	var target := Node2D.new()
	target.name = "ProbeTarget"
	scene.add_child(target)
	var input := Node.new()
	input.name = "ProbeInput"
	scene.add_child(input)
	var action := Node.new()
	action.name = "ProbeInputAction"
	scene.add_child(action)
	var finished := Node.new()
	finished.name = "ProbeFinishedSignal"
	scene.add_child(finished)
	var control := Control.new()
	control.name = "FixtureControl"
	scene.add_child(control)

	var scalar := (
		NodeOps
		. get_property(
			{
				"node_path": "/root/Task9Scene/ProbeInput",
				"property": "process_mode",
			}
		)
	)
	_assert_true(scalar.get("ok", false), "scalar property get returns successfully")
	_assert_eq(
		scalar.get("result", {}).get("value", null),
		Node.PROCESS_MODE_INHERIT,
		"scalar property get preserves the scalar value"
	)

	_assert_permission(
		(
			NodeOps
			. set_property(
				{
					"node_path": "/root/Task9Scene/ProbeInput",
					"property": "process_mode",
					"value": 0,
				}
			)
		),
		"infrastructure set"
	)
	_assert_permission(
		(
			NodeOps
			. call_method(
				{
					"node_path": "/root/Task9Scene/ProbeInput",
					"method": "queue_free",
				}
			)
		),
		"infrastructure call"
	)
	_assert_permission(
		NodeOps.remove({"node_path": "/root/Task9Scene/ProbeInput"}), "infrastructure remove"
	)
	_assert_permission(
		(
			NodeOps
			. reparent(
				{
					"node_path": "/root/Task9Scene/ProbeInputAction",
					"new_parent": "/root/Task9Scene/ProbeTarget",
				}
			)
		),
		"infrastructure reparent"
	)
	_assert_permission(
		(
			NodeOps
			. duplicate_node(
				{
					"node_path": "/root/Task9Scene/ProbeFinishedSignal",
					"name": "Task9InfrastructureDuplicate",
				}
			)
		),
		"infrastructure duplicate"
	)
	_assert_permission(
		(
			NodeOps
			. rename(
				{
					"node_path": "/root/Task9Scene/ProbeFinishedSignal",
					"name": "Task9InfrastructureRenamed",
				}
			)
		),
		"infrastructure rename"
	)
	_assert_permission(
		(
			NodeOps
			. duplicate_node(
				{
					"node_path": "/root/Task9Scene/ProbeTarget",
					"name": "Task10ProtectedDuplicate",
				}
			)
		),
		"fixed fixture duplicate"
	)
	_assert_permission(
		(
			NodeOps
			. reparent(
				{
					"node_path": "/root/Task9Scene/ProbeTarget",
					"new_parent": "/root/Task9Scene",
				}
			)
		),
		"fixed fixture reparent"
	)
	_assert_permission(
		(
			NodeOps
			. remove(
				{
					"node_path": "/root/Task9Scene/ProbeTarget",
				}
			)
		),
		"fixed fixture remove"
	)
	_assert_permission(
		(
			NodeOps
			. rename(
				{
					"node_path": "/root/Task9Scene/ProbeTarget",
					"name": "Task10ProtectedRename",
				}
			)
		),
		"fixed fixture rename"
	)
	_assert_true(
		(
			NodeOps
			. set_property(
				{
					"node_path": "/root/Task9Scene/ProbeTarget",
					"property": "process_mode",
					"value": Node.PROCESS_MODE_DISABLED,
				}
			)
			. get("ok", false)
		),
		"fixed fixture still permits allowlisted set"
	)
	_assert_permission(
		(
			NodeOps
			. set_property(
				{
					"node_path": "/root/Task9Scene/FixtureControl",
					"property": "visible",
					"value": false,
				}
			)
		),
		"unlisted fixture set"
	)

	var created := (
		NodeOps
		. create(
			{
				"parent_path": "/root/Task9Scene",
				"type": "Node2D",
				"name": "Task9Created",
			}
		)
	)
	_assert_true(created.get("ok", false), "created node is dedicated")
	var created_path := String(created.get("result", {}).get("node_path", ""))
	var moved := (
		NodeOps
		. reparent(
			{
				"node_path": created_path,
				"new_parent": "/root/Task9Scene/ProbeTarget",
			}
		)
	)
	_assert_true(moved.get("ok", false), "dedicated node can reparent")
	var moved_back := (
		NodeOps
		. reparent(
			{
				"node_path": "/root/Task9Scene/ProbeTarget/Task9Created",
				"new_parent": "/root/Task9Scene",
			}
		)
	)
	_assert_true(moved_back.get("ok", false), "dedicated node can reparent back")
	var removed := NodeOps.remove({"node_path": created_path})
	_assert_true(removed.get("ok", false), "dedicated node can be removed")

	var collision := (
		NodeOps
		. create(
			{
				"parent_path": "/root/Task9Scene",
				"type": "Node2D",
				"name": "Task10Collision",
			}
		)
	)
	_assert_true(collision.get("ok", false), "name-collision node is created")
	var collision_path := String(collision.get("result", {}).get("node_path", ""))
	var collision_nested := (
		NodeOps
		. reparent(
			{
				"node_path": collision_path,
				"new_parent": "/root/Task9Scene/ProbeTarget",
			}
		)
	)
	_assert_true(collision_nested.get("ok", false), "name-collision node can nest")
	var collision_renamed := (
		NodeOps
		. rename(
			{
				"node_path": "/root/Task9Scene/ProbeTarget/Task10Collision",
				"name": "ProbeTarget",
			}
		)
	)
	_assert_true(
		collision_renamed.get("ok", false), "nested runtime node can use fixed fixture name"
	)
	var nested_collision_path := "/root/Task9Scene/ProbeTarget/ProbeTarget"
	var collision_copy := (
		NodeOps
		. duplicate_node(
			{
				"node_path": nested_collision_path,
				"name": "Task10CollisionCopy",
			}
		)
	)
	_assert_true(collision_copy.get("ok", false), "nested same-name runtime node can duplicate")
	var collision_rename_again := (
		NodeOps
		. rename(
			{
				"node_path": nested_collision_path,
				"name": "Task10CollisionRenamed",
			}
		)
	)
	_assert_true(
		collision_rename_again.get("ok", false), "nested same-name runtime node can rename"
	)
	var rename_back := (
		NodeOps
		. rename(
			{
				"node_path": "/root/Task9Scene/ProbeTarget/Task10CollisionRenamed",
				"name": "ProbeTarget",
			}
		)
	)
	_assert_true(rename_back.get("ok", false), "runtime node can restore colliding name")
	var container := (
		NodeOps
		. create(
			{
				"parent_path": "/root/Task9Scene",
				"type": "Node",
				"name": "Task10Container",
			}
		)
	)
	_assert_true(container.get("ok", false), "name-collision container is created")
	var collision_reparented := (
		NodeOps
		. reparent(
			{
				"node_path": nested_collision_path,
				"new_parent": "/root/Task9Scene/Task10Container",
			}
		)
	)
	_assert_true(
		collision_reparented.get("ok", false), "nested same-name runtime node can reparent"
	)
	var collision_removed := (
		NodeOps
		. remove(
			{
				"node_path": "/root/Task9Scene/Task10Container/ProbeTarget",
			}
		)
	)
	_assert_true(collision_removed.get("ok", false), "nested same-name runtime node can remove")

	scene.free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _assert_permission(result: Dictionary, context: String) -> void:
	_assert_eq(result.get("code", ""), "permission_denied", context)


func _assert_true(value: bool, context: String) -> void:
	_assert_eq(value, true, context)


func _assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
