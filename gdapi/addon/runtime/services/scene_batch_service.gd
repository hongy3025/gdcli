@tool
class_name GdApiSceneBatchService
extends RefCounted

const BulkFiles := preload("res://addons/gdapi/runtime/services/bulk_file_service.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const STAGE_ROOT := "res://.godot/gdapi-scene-batch"


static func plan(body: Dictionary) -> Dictionary:
	return _build(body)


static func validate(body: Dictionary) -> Dictionary:
	var result := _build(body)
	if not result.ok:
		return result
	if String(body.get("plan_hash", "")) != result.plan_hash:
		return _error(
			ErrorCodes.CONFLICT, "plan_hash does not match parameters, scenes or dependencies"
		)
	result["validated"] = true
	return result


static func apply(body: Dictionary) -> Dictionary:
	var checked := validate(body)
	if not checked.ok:
		return checked
	if checked.operations.is_empty():
		return {
			"ok": true,
			"changed": false,
			"undoable": false,
			"files": 0,
			"plan_hash": checked.plan_hash
		}
	var operation_id := "%s-%s" % [Time.get_ticks_usec(), randi()]
	var stage := STAGE_ROOT.path_join(operation_id)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(stage)) != OK:
		return _error(ErrorCodes.GODOT_ERROR, "cannot create scene transaction directory")
	var built := _build(body, stage)
	if not built.ok or built.get("plan_hash", "") != checked.plan_hash:
		_cleanup(stage)
		return built if not built.ok else _error(ErrorCodes.CONFLICT, "scene changed while staging")
	var entries: Array = built.entries
	var manifest := {
		"operation_id": operation_id,
		"state": "prepared",
		"plan_hash": checked.plan_hash,
		"entries": entries
	}
	if not _write_manifest(stage, manifest):
		_cleanup(stage)
		return _error(ErrorCodes.GODOT_ERROR, "cannot persist scene recovery manifest")
	var rechecked := validate(body)
	if not rechecked.ok:
		_cleanup(stage)
		return rechecked
	var committed := _commit(entries, BulkFiles._debug_fail_after())
	if not committed.ok:
		if committed.get("details", {}).get("rollback_failures", []).is_empty():
			_cleanup(stage)
		else:
			committed["operation_id"] = operation_id
		return committed
	manifest.state = "applied"
	if not _write_manifest(stage, manifest):
		var failures := _rollback(entries, entries.size())
		if failures.is_empty():
			_cleanup(stage)
		return _transaction_error("cannot finalize recovery manifest", failures)
	_schedule_filesystem_refresh(entries)
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"files": entries.size(),
		"operation_id": operation_id,
		"plan_hash": checked.plan_hash
	}


static func recover(body: Dictionary) -> Dictionary:
	var operation_id := String(body.get("operation_id", ""))
	if operation_id.is_empty() or operation_id.count("-") != 1:
		return _error(ErrorCodes.INVALID_PARAM, "invalid operation_id")
	for part in operation_id.split("-"):
		if not part.is_valid_int() or part.begins_with("-"):
			return _error(ErrorCodes.INVALID_PARAM, "invalid operation_id")
	var stage := STAGE_ROOT.path_join(operation_id)
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(stage.path_join("manifest.json"))
	)
	if not parsed is Dictionary or parsed.get("operation_id", "") != operation_id:
		return _error(ErrorCodes.NOT_FOUND, "valid scene recovery manifest not found")
	if parsed.get("state", "") != "applied":
		return _error(ErrorCodes.CONFLICT, "transaction is not in applied state")
	var entries: Variant = parsed.get("entries")
	if not entries is Array or entries.is_empty() or entries.size() > BulkFiles.MAX_FILES:
		return _error(ErrorCodes.CONFLICT, "invalid recovery entries")
	var restores: Array = []
	var seen: Array = []
	for index in range(entries.size()):
		var entry: Variant = entries[index]
		if not entry is Dictionary:
			return _error(ErrorCodes.CONFLICT, "invalid recovery entry")
		var source := String(entry.get("path", ""))
		var guard := _writable(source)
		if not guard.ok:
			return guard
		if (
			source in seen
			or (
				String(entry.get("backup", ""))
				!= stage.path_join("backup-%d.%s" % [index, source.get_extension()])
			)
		):
			return _error(ErrorCodes.CONFLICT, "invalid recovery backup path")
		seen.append(source)
		if (
			_sha(source) != entry.get("after_sha256", "")
			or _sha(entry.backup) != entry.get("before_sha256", "")
		):
			return _error(
				ErrorCodes.CONFLICT, "recovery conflicts with changed scene or backup: " + source
			)
		var deps := _dependencies(source)
		if not deps.ok:
			return deps
		if (
			BulkFiles._hash_plan(deps.items)
			!= BulkFiles._hash_plan(entry.get("after_dependencies", []))
		):
			return _error(ErrorCodes.CONFLICT, "recovery dependency changed: " + source)
		for dependency in entry.get("dependencies", []):
			if (
				not dependency is Dictionary
				or _sha(String(dependency.get("path", ""))) != dependency.get("sha256", "")
			):
				return _error(ErrorCodes.CONFLICT, "original or target resource dependency changed")
		var staged := stage.path_join("restore-%d.%s" % [index, source.get_extension()])
		if (
			(
				DirAccess.copy_absolute(
					ProjectSettings.globalize_path(entry.backup),
					ProjectSettings.globalize_path(staged)
				)
				!= OK
			)
			or _sha(staged) != entry.before_sha256
		):
			return _error(ErrorCodes.GODOT_ERROR, "cannot stage recovery")
		var load_check := _load_scene(staged)
		if not load_check.ok:
			return load_check
		load_check.root.free()
		restores.append(
			{
				"path": source,
				"staged": staged,
				"backup":
				stage.path_join("recovery-backup-%d.%s" % [index, source.get_extension()]),
				"before_sha256": entry.after_sha256,
				"after_sha256": entry.before_sha256
			}
		)
		restores[-1]["dependencies"] = deps.items + entry.get("dependencies", [])
	var committed := _commit(restores, BulkFiles._debug_recover_fail_after())
	if not committed.ok:
		return committed
	parsed.state = "recovered"
	if not _write_manifest(stage, parsed):
		return _transaction_error("cannot finalize recovery", _rollback(restores, restores.size()))
	_schedule_filesystem_refresh(restores)
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"restored": restores.size(),
		"operation_id": operation_id
	}


static func find_nodes_by_type(body: Dictionary) -> Dictionary:
	var selected := _selection(
		body.get("selector", {"class": body.get("class", body.get("type", ""))})
	)
	if not selected.ok:
		return selected
	var scan := _scenes(body)
	if not scan.ok:
		return scan
	var items: Array = []
	for path in scan.paths:
		var loaded := _load_scene(path)
		if not loaded.ok:
			return loaded
		for node in _nodes(loaded.root):
			if _matches(node, loaded.root, selected.selector):
				items.append(
					{
						"path": path,
						"node_path": String(loaded.root.get_path_to(node)),
						"name": String(node.name),
						"class": node.get_class(),
						"instance": node.scene_file_path
					}
				)
		loaded.root.free()
	return {"ok": true, "items": items, "scenes": scan.paths.size(), "warnings": scan.warnings}


static func find_node_references(body: Dictionary) -> Dictionary:
	var scan := _scenes(body)
	if not scan.ok:
		return scan
	var target := String(body.get("node_path", ""))
	var items: Array = []
	for path in scan.paths:
		var loaded := _load_scene(path)
		if not loaded.ok:
			return loaded
		var root: Node = loaded.root
		for node in _nodes(root):
			var node_path := String(root.get_path_to(node))
			for info in node.get_property_list():
				if not (int(info.usage) & PROPERTY_USAGE_STORAGE):
					continue
				_collect_nodepaths(
					node.get(info.name), String(info.name), node, root, path, target, items
				)
			if node.scene_file_path != "" and node != root:
				if target.is_empty() or target == node.scene_file_path or target == node_path:
					items.append(
						{
							"path": path,
							"node_path": node_path,
							"kind": "instance",
							"target": node.scene_file_path
						}
					)
		var state: SceneState = loaded.scene.get_state()
		for index in range(state.get_connection_count()):
			var source := String(state.get_connection_source(index))
			var destination := String(state.get_connection_target(index))
			if target.is_empty() or target in [source, destination]:
				items.append(
					{
						"path": path,
						"node_path": source,
						"kind": "connection",
						"target": destination,
						"signal": String(state.get_connection_signal(index)),
						"method": String(state.get_connection_method(index))
					}
				)
		root.free()
	return {"ok": true, "items": items, "warnings": scan.warnings}


static func get_scene_dependencies(body: Dictionary) -> Dictionary:
	var scan := _scenes(body)
	if not scan.ok:
		return scan
	var items: Array = []
	for path in scan.paths:
		var deps := _dependencies(path)
		if not deps.ok:
			return deps
		for dependency in deps.items:
			items.append(
				{
					"path": path,
					"dependency": dependency.path,
					"sha256": dependency.sha256,
					"via": dependency.via,
					"uid": dependency.uid
				}
			)
	return {"ok": true, "items": items, "warnings": scan.warnings}


static func _build(body: Dictionary, stage: String = "") -> Dictionary:
	var requests: Variant = body.get("operations", [])
	if not requests is Array or requests.is_empty() or requests.size() > BulkFiles.MAX_REPLACEMENTS:
		return _error(
			ErrorCodes.INVALID_PARAM,
			"operations must be a nonempty array of set_property operations"
		)
	for request in requests:
		if (
			not request is Dictionary
			or request.get("op", "set_property") != "set_property"
			or not request.has("value")
			or not request.get("property", "") is String
		):
			return _error(
				ErrorCodes.INVALID_PARAM,
				"each operation requires op:set_property, property and value"
			)
		var selection := _selection(request.get("selector", body.get("selector", {})))
		if not selection.ok:
			return selection
		if request.has("scene"):
			if not request.scene is String:
				return _error(ErrorCodes.INVALID_PARAM, "operation scene must be a path string")
			var guard := PathGuard.validate(request.scene, "write")
			if not guard.ok:
				return guard
	var scan := _scenes(body)
	if not scan.ok:
		return scan
	for request in requests:
		if request.has("scene") and not PathGuard.normalize(request.scene) in scan.paths:
			return _error(ErrorCodes.NOT_FOUND, "operation scene is outside the scene selection")
	var operations: Array = []
	var matches: Array = []
	var scenes: Array = []
	var entries: Array = []
	for path in scan.paths:
		var before_sha256 := _sha(path)
		var deps := _dependencies(path)
		if not deps.ok:
			return deps
		var loaded := _load_scene(path)
		if not loaded.ok:
			return loaded
		var root: Node = loaded.root
		var nodes := _nodes(root)
		var scene_operations: Array = []
		var failure := {"ok": true}
		var touched: Array = []
		for request in requests:
			if request.has("scene") and PathGuard.normalize(String(request.scene)) != path:
				continue
			var selector: Dictionary = request.get("selector", body.get("selector", {}))
			for node in nodes:
				if not _matches(node, root, selector):
					continue
				var property := String(request.property)
				var node_path := String(root.get_path_to(node))
				var key := node_path + ":" + property
				if key in touched:
					failure = _error(
						ErrorCodes.INVALID_PARAM, "duplicate node property operation: " + key
					)
					break
				var checked := _property(node, property, request.value)
				if not checked.ok:
					failure = checked
					break
				touched.append(key)
				var previous: Variant = node.get(property)
				var target: Variant = checked.value
				var target_dependencies := _target_dependencies(target)
				if not target_dependencies.ok:
					failure = target_dependencies
					break
				deps.items.append_array(target_dependencies.items)
				var changed: bool = _fingerprint(previous) != _fingerprint(target)
				var operation := {
					"scene": path,
					"node_path": node_path,
					"class": node.get_class(),
					"name": String(node.name),
					"op": "set_property",
					"property": property,
					"previous": VariantCodec.from_variant(previous),
					"value": VariantCodec.from_variant(target),
					"changed": changed
				}
				matches.append(operation)
				if matches.size() > BulkFiles.MAX_REPLACEMENTS:
					failure = _error(
						ErrorCodes.INVALID_PARAM, "scene transaction exceeds bulk operation limit"
					)
					break
				if not changed:
					continue
				var ancestor: Node = node
				while ancestor != root:
					if ancestor.scene_file_path != "":
						root.set_editable_instance(ancestor, true)
					ancestor = ancestor.get_parent()
				node.set(property, target)
				var stored: Variant = node.get(property)
				var rejected: bool = _fingerprint(stored) != _fingerprint(target)
				if typeof(stored) == TYPE_FLOAT and typeof(target) == TYPE_FLOAT:
					rejected = not is_equal_approx(stored, target)
				if rejected:
					failure = _error(
						ErrorCodes.INVALID_PARAM, "property setter rejected value: " + key
					)
					break
				scene_operations.append(operation)
			if not failure.ok:
				break
		if not failure.ok:
			root.free()
			return failure
		var uid := ResourceLoader.get_resource_uid(path)
		scenes.append(
			{
				"path": path,
				"sha256": before_sha256,
				"uid": ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else "",
				"dependencies": deps.items,
				"matches": touched.size(),
				"changes": scene_operations.size()
			}
		)
		if not scene_operations.is_empty():
			var writable := _writable(path)
			if not writable.ok:
				root.free()
				return writable
			operations.append_array(scene_operations)
			if not stage.is_empty():
				var index := entries.size()
				var staged := stage.path_join("staged-%d.%s" % [index, path.get_extension()])
				var packed := PackedScene.new()
				var expected := _snapshot(root)
				if packed.pack(root) != OK or ResourceSaver.save(packed, staged) != OK:
					root.free()
					return _error(ErrorCodes.GODOT_ERROR, "cannot pack/stage scene: " + path)
				if uid != ResourceUID.INVALID_ID and ResourceSaver.set_uid(staged, uid) != OK:
					root.free()
					return _error(ErrorCodes.GODOT_ERROR, "cannot preserve scene UID")
				var readback := _load_scene(staged)
				if not readback.ok:
					root.free()
					return readback
				var actual := _snapshot(readback.root)
				readback.root.free()
				if expected != actual:
					root.free()
					return _error(
						ErrorCodes.GODOT_ERROR,
						"staged scene read-back changed properties, owners or instances: " + path
					)
				var after_dependencies := _dependencies(staged)
				if not after_dependencies.ok:
					root.free()
					return after_dependencies
				for dependency in after_dependencies.items:
					if dependency.via == staged:
						dependency.via = path
				after_dependencies.items.sort_custom(
					func(a, b): return (a.path + a.via) < (b.path + b.via)
				)
				entries.append(
					{
						"path": path,
						"staged": staged,
						"backup": stage.path_join("backup-%d.%s" % [index, path.get_extension()]),
						"before_sha256": before_sha256,
						"after_sha256": _sha(staged),
						"dependencies": deps.items,
						"after_dependencies": after_dependencies.items
					}
				)
		root.free()
	var parameters := body.duplicate(true)
	parameters.erase("plan_hash")
	parameters.erase("dry_run")
	var result := {
		"ok": true,
		"scenes": scenes,
		"matches": matches,
		"operations": operations,
		"warnings": scan.warnings,
		"plan_hash":
		BulkFiles._hash_plan({"parameters": parameters, "scenes": scenes, "operations": operations})
	}
	if operations.is_empty():
		result.warnings.append("No changed properties matched the selection")
	if not stage.is_empty():
		result["entries"] = entries
	return result


static func _selection(raw: Variant) -> Dictionary:
	if not raw is Dictionary or raw.is_empty():
		return _error(ErrorCodes.INVALID_PARAM, "selector requires class, name or node_path")
	for key in raw:
		if (
			key not in ["class", "name", "node_path"]
			or not raw[key] is String
			or raw[key].is_empty()
		):
			return _error(
				ErrorCodes.INVALID_PARAM, "selector accepts nonempty class/name/node_path strings"
			)
	if raw.has("class") and not ClassDB.class_exists(raw["class"]):
		return _error(ErrorCodes.INVALID_PARAM, "unknown node class")
	if raw.has("node_path"):
		var path := NodePath(raw.node_path)
		if path.is_absolute() or path.get_subname_count() > 0 or String(path).split("/").has(".."):
			return _error(
				ErrorCodes.INVALID_PATH, "selector node_path must be relative to the scene root"
			)
	return {"ok": true, "selector": raw}


static func _matches(node: Node, root: Node, selector: Dictionary) -> bool:
	return (
		(not selector.has("class") or node.is_class(selector["class"]))
		and (not selector.has("name") or String(node.name).match(selector.name))
		and (not selector.has("node_path") or String(root.get_path_to(node)) == selector.node_path)
	)


static func _property(node: Node, property: String, raw: Variant) -> Dictionary:
	var guard := NodeEditor.check_property(node, property)
	if not guard.ok:
		return guard
	if (
		property.contains("/")
		or property.contains(":")
		or property in ["owner", "name", "scene_file_path", "unique_name_in_owner"]
	):
		return _error(
			ErrorCodes.PERMISSION_DENIED,
			"structural or nested object property is protected: " + property
		)
	var info: Dictionary = {}
	for item in node.get_property_list():
		if String(item.name) == property:
			info = item
			break
	if (
		not (int(info.usage) & PROPERTY_USAGE_STORAGE)
		or (int(info.usage) & PROPERTY_USAGE_READ_ONLY)
	):
		return _error(
			ErrorCodes.PERMISSION_DENIED, "property is not writable scene storage: " + property
		)
	var decoded := _decode(raw)
	if not decoded.ok:
		return decoded
	var value: Variant = decoded.value
	var expected := int(info.type)
	if expected == TYPE_OBJECT:
		if value != null and not value is Resource:
			return _error(
				ErrorCodes.PERMISSION_DENIED, "object writes require a path-guarded Resource"
			)
		if value is Script:
			return _error(ErrorCodes.PERMISSION_DENIED, "script writes are protected")
		if (
			value != null
			and not String(info.class_name).is_empty()
			and not value.is_class(info.class_name)
		):
			return _error(ErrorCodes.INVALID_PARAM, "resource class does not match property")
	elif typeof(value) != expected:
		if expected == TYPE_FLOAT and typeof(value) == TYPE_INT:
			value = float(value)
		elif expected == TYPE_INT and typeof(value) == TYPE_FLOAT and value == floor(value):
			value = int(value)
		elif expected == TYPE_STRING_NAME and typeof(value) == TYPE_STRING:
			value = StringName(value)
		else:
			return _error(ErrorCodes.INVALID_PARAM, "wrong value type for property: " + property)
	return {"ok": true, "value": value}


static func _decode(raw: Variant) -> Dictionary:
	if raw is Dictionary and raw.get("type", "") == "Resource":
		var guard := PathGuard.validate(String(raw.get("value", "")), "write")
		if not guard.ok:
			return guard
		if not ResourceLoader.exists(guard.path):
			return _error(ErrorCodes.NOT_FOUND, "resource dependency not found")
	if raw is Array:
		var values: Array = []
		for item in raw:
			var decoded := _decode(item)
			if not decoded.ok:
				return decoded
			values.append(decoded.value)
		return {"ok": true, "value": values}
	if raw is Dictionary and not raw.has("type"):
		var values: Dictionary = {}
		for key in raw:
			var decoded := _decode(raw[key])
			if not decoded.ok:
				return decoded
			values[key] = decoded.value
		return {"ok": true, "value": values}
	var result := VariantCodec.decode(raw)
	if not result.ok:
		return _error(ErrorCodes.INVALID_PARAM, result.error)
	if result.value is Script or result.value is Node:
		return _error(ErrorCodes.PERMISSION_DENIED, "script and node object writes are protected")
	return result


static func _scenes(body: Dictionary) -> Dictionary:
	var paths: Array = []
	var warnings: Array = []
	if body.has("scenes"):
		if not body.scenes is Array or body.scenes.is_empty():
			return _error(ErrorCodes.INVALID_PARAM, "scenes must be a nonempty array")
		for raw in body.scenes:
			if not raw is String:
				return _error(ErrorCodes.INVALID_PARAM, "scene paths must be strings")
			var guard := PathGuard.validate(raw, "write")
			if not guard.ok:
				return guard
			if (
				guard.path.get_extension() not in ["tscn", "scn"]
				or not FileAccess.file_exists(guard.path)
			):
				return _error(ErrorCodes.NOT_FOUND, "scene not found: " + guard.path)
			if not guard.path in paths:
				paths.append(guard.path)
	else:
		var guard := PathGuard.validate(String(body.get("root", "res://")), "write")
		if not guard.ok:
			return guard
		var result := _scan(guard.path, paths, warnings)
		if not result.ok:
			return result
	if paths.size() > BulkFiles.MAX_FILES:
		return _error(ErrorCodes.INVALID_PARAM, "scene scan exceeds bulk file limit")
	paths.sort()
	return {"ok": true, "paths": paths, "warnings": warnings}


static func _scan(root: String, paths: Array, warnings: Array) -> Dictionary:
	var directory := DirAccess.open(root)
	if directory == null:
		return _error(ErrorCodes.NOT_FOUND, "scene scan root not found: " + root)
	for name in directory.get_files():
		if name.get_extension() in ["tscn", "scn"]:
			var path := root.path_join(name)
			if PathGuard.validate(path, "write").ok:
				paths.append(path)
			if paths.size() > BulkFiles.MAX_FILES:
				return _error(ErrorCodes.INVALID_PARAM, "scene scan exceeds bulk file limit")
	for name in directory.get_directories():
		var path := root.path_join(name)
		if (
			name.begins_with(".")
			or directory.is_link(name)
			or not PathGuard.validate(path, "write").ok
		):
			warnings.append("Excluded generated/protected/link directory: " + path)
			continue
		var result := _scan(path, paths, warnings)
		if not result.ok:
			return result
	return {"ok": true}


static func _load_scene(path: String) -> Dictionary:
	var resource := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if not resource is PackedScene or not resource.can_instantiate():
		return _error(ErrorCodes.GODOT_ERROR, "cannot load scene: " + path)
	var root: Node = resource.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		return _error(ErrorCodes.GODOT_ERROR, "cannot instantiate scene: " + path)
	return {"ok": true, "root": root, "scene": resource}


static func _refresh_scene_cache(entries: Array) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": true}
	for entry in entries:
		var resource := ResourceLoader.load(
			entry.path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE
		)
		if not resource is PackedScene or not resource.can_instantiate():
			return _error(
				ErrorCodes.GODOT_ERROR, "cannot refresh editor scene cache: " + entry.path
			)
	return {"ok": true}


static func _schedule_filesystem_refresh(entries: Array) -> void:
	if not Engine.is_editor_hint():
		return
	var file_system := EditorInterface.get_resource_filesystem()
	for entry in entries:
		file_system.update_file(entry.path)
	file_system.scan()


static func _nodes(root: Node) -> Array:
	var nodes: Array = [root]
	for child in root.get_children():
		if child.owner != null:
			nodes.append_array(_nodes(child))
	return nodes


static func _dependencies(path: String, seen: Array = []) -> Dictionary:
	var items: Array = []
	if path in seen:
		return {"ok": true, "items": items}
	seen.append(path)
	for raw in ResourceLoader.get_dependencies(path):
		var parts := String(raw).split("::")
		var dependency := String(parts[-1])
		var uid := String(parts[0]) if String(parts[0]).begins_with("uid://") else ""
		if dependency.begins_with("uid://"):
			var id := ResourceUID.text_to_id(dependency)
			dependency = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
		var guard := PathGuard.validate(dependency, "read")
		if not guard.ok:
			return guard
		if not FileAccess.file_exists(guard.path):
			return _error(ErrorCodes.NOT_FOUND, "missing scene dependency: " + dependency)
		items.append({"path": guard.path, "sha256": _sha(guard.path), "via": path, "uid": uid})
		var nested := _dependencies(guard.path, seen)
		if not nested.ok:
			return nested
		items.append_array(nested.items)
	items.sort_custom(func(a, b): return (a.path + a.via) < (b.path + b.via))
	return {"ok": true, "items": items}


static func _writable(path: String) -> Dictionary:
	var guard := PathGuard.validate(path, "write")
	if not guard.ok:
		return guard
	if SceneEditor.list_open_scenes().has(guard.path):
		return _error(
			ErrorCodes.CONFLICT,
			"close affected scene first; open scenes may contain unsaved changes: " + path
		)
	if FileAccess.get_read_only_attribute(guard.path):
		return _error(ErrorCodes.PERMISSION_DENIED, "scene file is read-only: " + path)
	return guard


static func _commit(entries: Array, fail_after: int) -> Dictionary:
	# Recheck every destination before the first rename, never partially validate.
	for entry in entries:
		var guard := _writable(entry.path)
		if not guard.ok:
			return guard
		if _sha(entry.path) != entry.before_sha256 or _sha(entry.staged) != entry.after_sha256:
			return _error(
				ErrorCodes.CONFLICT, "transaction source/stage hash changed: " + entry.path
			)
		for dependency in entry.get("dependencies", []):
			if _sha(dependency.path) != dependency.sha256:
				return _error(
					ErrorCodes.CONFLICT, "transaction dependency changed: " + dependency.path
				)
	var moved := 0
	for entry in entries:
		if fail_after >= 0 and moved >= fail_after:
			return _transaction_error(
				"injected scene transaction failure", _rollback(entries, moved)
			)
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(entry.path),
				ProjectSettings.globalize_path(entry.backup)
			)
			!= OK
		):
			return _transaction_error("cannot back up scene", _rollback(entries, moved))
		moved += 1
		if (
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(entry.staged),
				ProjectSettings.globalize_path(entry.path)
			)
			!= OK
		):
			return _transaction_error("cannot replace scene", _rollback(entries, moved))
		if _sha(entry.path) != entry.after_sha256:
			return _transaction_error(
				"scene write read-back hash failed", _rollback(entries, moved)
			)
		var readback := _load_scene(entry.path)
		if not readback.ok:
			return _transaction_error("scene write reload failed", _rollback(entries, moved))
		readback.root.free()
	var refreshed := _refresh_scene_cache(entries)
	if not refreshed.ok:
		var failures := _rollback(entries, moved)
		var restored := _refresh_scene_cache(entries)
		if not restored.ok:
			failures.append("editor resource cache")
		var result := _transaction_error("scene cache refresh failed", failures)
		result.details.cache_error = refreshed.error
		return result
	return {"ok": true}


static func _rollback(entries: Array, count: int) -> Array:
	var failures: Array = []
	for index in range(count - 1, -1, -1):
		var entry: Dictionary = entries[index]
		var source := ProjectSettings.globalize_path(entry.path)
		if FileAccess.file_exists(source) and DirAccess.remove_absolute(source) != OK:
			failures.append(entry.path)
			continue
		if (
			DirAccess.rename_absolute(ProjectSettings.globalize_path(entry.backup), source) != OK
			or _sha(entry.path) != entry.before_sha256
		):
			failures.append(entry.path)
	return failures


static func _write_manifest(stage: String, manifest: Dictionary) -> bool:
	var target := stage.path_join("manifest.json")
	var temporary := target + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	var text := JSON.stringify(manifest)
	file.store_string(text)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or FileAccess.get_file_as_string(temporary) != text:
		return false
	return (
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(target)
		)
		== OK
	)


static func _snapshot(root: Node) -> String:
	var rows: Array = []
	for node in _nodes(root):
		var properties: Dictionary = {}
		for info in node.get_property_list():
			if (
				int(info.usage) & PROPERTY_USAGE_STORAGE
				and String(info.name) not in ["scene_file_path", "owner"]
			):
				properties[info.name] = _fingerprint(node.get(info.name))
		var connections: Array = []
		for signal_info in node.get_signal_list():
			for connection in node.get_signal_connection_list(signal_info.name):
				if int(connection.flags) & CONNECT_PERSIST:
					var callable: Callable = connection.callable
					var target: Object = callable.get_object()
					connections.append(
						{
							"signal": String(signal_info.name),
							"target": String(root.get_path_to(target)) if target is Node else "",
							"method": String(callable.get_method()),
							"binds": _fingerprint(callable.get_bound_arguments()),
							"flags": connection.flags
						}
					)
		for connection in connections:
			connection["_sort_key"] = JSON.stringify(connection)
		connections.sort_custom(func(a, b): return a._sort_key < b._sort_key)
		for connection in connections:
			connection.erase("_sort_key")
		var groups: Array = []
		for group in node.get_groups():
			if not String(group).begins_with("_"):
				groups.append(String(group))
		groups.sort()
		rows.append(
			{
				"path": String(root.get_path_to(node)),
				"class": node.get_class(),
				"owner": String(root.get_path_to(node.owner)) if node.owner != null else "",
				"instance": node.scene_file_path if node != root else "",
				"properties": properties,
				"connections": connections,
				"groups": groups
			}
		)
	return BulkFiles._hash_plan(rows)


static func _fingerprint(value: Variant, depth: int = 0) -> Variant:
	if depth > 16:
		return "<resource-cycle>"
	if value is Resource:
		if not value.resource_path.is_empty() and not value.resource_path.contains("::"):
			return {"resource": value.resource_path}
		var props: Dictionary = {"class": value.get_class()}
		for info in value.get_property_list():
			if int(info.usage) & PROPERTY_USAGE_STORAGE and String(info.name) != "resource_path":
				props[info.name] = _fingerprint(value.get(info.name), depth + 1)
		return props
	if value is Array:
		var values: Array = []
		for item in value:
			values.append(_fingerprint(item, depth + 1))
		return values
	if value is Dictionary:
		var values: Dictionary = {}
		for key in value:
			values[str(key)] = _fingerprint(value[key], depth + 1)
		return values
	if value is Object:
		return value.get_class()
	return var_to_str(value)


static func _collect_nodepaths(
	value: Variant,
	property: String,
	node: Node,
	root: Node,
	path: String,
	target: String,
	items: Array
) -> void:
	if value is NodePath:
		var resolved: Node = node.get_node_or_null(value)
		var destination := String(root.get_path_to(resolved)) if resolved != null else String(value)
		if target.is_empty() or target == destination or target == String(value):
			items.append(
				{
					"path": path,
					"node_path": String(root.get_path_to(node)),
					"kind": "property",
					"property": property,
					"value": String(value),
					"target": destination,
					"resolved": resolved != null
				}
			)
	elif value is Array:
		for index in range(value.size()):
			_collect_nodepaths(
				value[index], "%s[%d]" % [property, index], node, root, path, target, items
			)
	elif value is Dictionary:
		for key in value:
			_collect_nodepaths(
				value[key], "%s[%s]" % [property, key], node, root, path, target, items
			)


static func _sha(path: String) -> String:
	return FileAccess.get_sha256(ProjectSettings.globalize_path(path))


static func _cleanup(stage: String) -> void:
	BulkFiles._remove_tree(
		ProjectSettings.globalize_path(stage), ProjectSettings.globalize_path(STAGE_ROOT)
	)


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}


static func _transaction_error(message: String, failures: Array) -> Dictionary:
	return {
		"ok": false,
		"code": ErrorCodes.GODOT_ERROR,
		"error": message,
		"changed": not failures.is_empty(),
		"undoable": false,
		"details": {"rollback_failures": failures}
	}


static func _target_dependencies(value: Variant) -> Dictionary:
	var items: Array = []
	if value is Resource:
		if value.resource_path.is_empty() or value.resource_path.contains("::"):
			return _error(
				ErrorCodes.PERMISSION_DENIED, "resource writes require an external resource path"
			)
		var guard := PathGuard.validate(value.resource_path, "write")
		if not guard.ok:
			return guard
		items.append({"path": guard.path, "sha256": _sha(guard.path), "via": "<target>", "uid": ""})
		var nested := _dependencies(guard.path)
		if not nested.ok:
			return nested
		items.append_array(nested.items)
	elif value is Array or value is Dictionary:
		var values: Array = value.values() if value is Dictionary else value
		for item in values:
			var nested := _target_dependencies(item)
			if not nested.ok:
				return nested
			items.append_array(nested.items)
	return {"ok": true, "items": items}
