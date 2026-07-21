## M2 节点编辑服务
##
## 提供按 NodePath 解析节点、Undoing 节点创建/删除/复制/重命名/reparent/move、属性
## set/reset/revert、list/select 等操作。所有编辑器状态 mutation 均接入 UndoRedo。
## 危险属性(脚本源码等)通过 `RESERVED_PROPERTIES` 显式拒绝。

@tool
class_name GdApiNodeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")

## 禁止脚本直接修改的属性,统一返回 permission_denied
const RESERVED_PROPERTIES := ["script", "script/source_code"]

## 在当前编辑场景中按 NodePath 解析节点,无效路径返回 {ok:false}
static func find(node_path: String) -> Dictionary:
	if node_path == "":
		return {"ok": false, "code": ErrorCodes.MISSING_PARAM, "error": "node_path is required"}
	if not Engine.is_editor_hint():
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "node_editor requires editor"}
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	if not node_path.begins_with("/root/"):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "node_path must be an absolute scene-root path beginning with /root/",
		}
	# 在编辑器场景中,从 EditInterface.get_edited_scene_root 开始解析.
	# `/root/Main/Player/Child` 先去掉与编辑场景根同名的那一段,再用相对路径查询。
	var rel := node_path.substr("/root/".length())
	if rel == "" or rel == String(edited.name):
		return {"ok": true, "node": edited, "node_path": "/root/" + String(edited.name)}
	var rel_parts := rel.split("/", false)
	if rel_parts.size() > 0 and rel_parts[0] == String(edited.name):
		rel_parts = rel_parts.slice(1)
	var rel_clean := "/".join(rel_parts)
	if rel_clean == "":
		return {"ok": true, "node": edited, "node_path": "/root/" + String(edited.name)}
	var node: Node = edited.get_node_or_null(NodePath(rel_clean))
	if node == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "node not found: " + node_path}
	return {"ok": true, "node": node, "node_path": "/root/" + String(edited.name) + "/" + rel_clean}

## 验证属性名,拒绝脚本源码类保留属性
static func check_property(target: Object, property: StringName) -> Dictionary:
	if property in RESERVED_PROPERTIES:
		return {
			"ok": false,
			"code": ErrorCodes.PERMISSION_DENIED,
			"error": "property is protected: " + property,
		}
	var exists := false
	for info in target.get_property_list():
		if info.name == property:
			exists = true
			break
	if not exists:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "property does not exist: " + property,
		}
	return {"ok": true}

## 按 type 创建一个属于 current edited scene 的子节点.
## 通过 GdApiEditAction.undo_redo() 提交 do/undo action.
static func create_node(parent_path: String, type: String, name: String) -> Dictionary:
	var parent_lookup := find(parent_path)
	if not parent_lookup.ok:
		return parent_lookup
	var parent: Node = parent_lookup.node
	if not ClassDB.class_exists(type):
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "unknown type: " + type}
	if not (ClassDB.is_parent_class(type, "Node") or type == "Node"):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "type is not a Node subclass: " + type,
		}
	var node: Node = ClassDB.instantiate(type)
	if node == null:
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "failed to instantiate: " + type,
		}
	var owner: Node = EditorInterface.get_edited_scene_root()
	var manager := EditAction.undo_redo()
	if manager == null:
		node.free()
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var unique := _unique_name(parent, name)
	manager.create_action("gdcli: create node", UndoRedo.MERGE_DISABLE, owner)
	manager.add_do_method(parent, "add_child", node, true)
	manager.add_do_method(node, "set_owner", owner)
	manager.add_do_reference(node)
	manager.add_undo_method(parent, "remove_child", node)
	manager.commit_action()
	node.name = unique
	node.owner = owner
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": _user_path_for(node),
		"name": unique,
		"type": type,
	}

static func _unique_name(parent: Node, base: String) -> String:
	var name := base if base != "" else "Node"
	var idx := 1
	while parent.has_node(NodePath(name)):
		idx += 1
		name = "%s%d" % [base, idx]
	return name

## delete 通过 UndoRedo 显式 remove_child + queue_free (do) / 重新加入 (undo).
static func delete_node(node_path: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var owner: Node = EditorInterface.get_edited_scene_root()
	if node == owner:
		return {
			"ok": false,
			"code": ErrorCodes.PERMISSION_DENIED,
			"error": "cannot delete scene root",
		}
	var parent: Node = node.get_parent()
	var index := node.get_index()
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	manager.create_action("gdcli: delete node", UndoRedo.MERGE_DISABLE, owner)
	manager.add_do_method(parent, "remove_child", node)
	manager.add_do_method(node, "queue_free")
	manager.add_undo_method(parent, "add_child", node)
	manager.add_undo_method(node, "set_owner", owner)
	manager.add_do_reference(node)
	manager.commit_action()
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": lookup.node_path,
	}

## duplicate 复制节点及其子节点,接 UndoRedo
static func duplicate_node(node_path: String, name: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var src: Node = lookup.node
	var owner: Node = EditorInterface.get_edited_scene_root()
	var dup := src.duplicate(Node.DUPLICATE_USE_INSTANTIATION or Node.DUPLICATE_SCRIPTS or Node.DUPLICATE_GROUPS or Node.DUPLICATE_SIGNALS)
	if dup == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "failed to duplicate"}
	var parent: Node = src.get_parent()
	var manager := EditAction.undo_redo()
	if manager == null:
		dup.free()
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var unique := _unique_name(parent, name if name != "" else String(src.name) + "_dup")
	manager.create_action("gdcli: duplicate node", UndoRedo.MERGE_DISABLE, owner)
	manager.add_do_method(parent, "add_child", dup, true)
	manager.add_do_method(dup, "set_owner", owner)
	manager.add_do_reference(dup)
	manager.add_undo_method(parent, "remove_child", dup)
	manager.commit_action()
	dup.name = unique
	dup.owner = owner
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": _user_path_for(dup),
		"name": unique,
		"type": dup.get_class(),
	}

## 节点改名通过 EditAction.commit_property 提交
static func rename_node(node_path: String, name: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	if name == "":
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "name is required"}
	var parent: Node = node.get_parent()
	var unique := _unique_name(parent, name)
	var result := EditAction.commit_property(node, &"name", unique, "gdcli: rename node")
	if not result.ok:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": result.error}
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": _user_path_for(node),
		"name": unique,
	}

## reparent 节点到 new_parent_path
static func reparent_node(node_path: String, parent_path: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var parent_lookup := find(parent_path)
	if not parent_lookup.ok:
		return parent_lookup
	var node: Node = lookup.node
	var new_parent: Node = parent_lookup.node
	var owner: Node = EditorInterface.get_edited_scene_root()
	if node == owner:
		return {
			"ok": false,
			"code": ErrorCodes.PERMISSION_DENIED,
			"error": "cannot reparent scene root",
		}
	if _is_ancestor(node, new_parent):
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "cannot reparent node into its own descendant",
		}
	var old_parent: Node = node.get_parent()
	if old_parent == null:
		return {
			"ok": false,
			"code": ErrorCodes.CONFLICT,
			"error": "node has no parent to reparent from",
		}
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	manager.create_action("gdcli: reparent node", UndoRedo.MERGE_DISABLE, owner)
	manager.add_do_method(old_parent, "remove_child", node)
	manager.add_do_method(new_parent, "add_child", node, true)
	manager.add_do_method(node, "set_owner", owner)
	manager.add_undo_method(new_parent, "remove_child", node)
	manager.add_undo_method(old_parent, "add_child", node)
	manager.commit_action()
	node.owner = owner
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": lookup.node_path,
	}

static func _is_ancestor(node: Node, candidate: Node) -> bool:
	var cur := candidate
	while cur != null:
		if cur == node:
			return true
		cur = cur.get_parent()
	return false

## move 改变节点的 sibling index
static func move_node(node_path: String, target_path: String, position: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var target_lookup := find(target_path)
	if not target_lookup.ok:
		return target_lookup
	var node: Node = lookup.node
	var target: Node = target_lookup.node
	if node.get_parent() != target.get_parent():
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "move target must share the same parent as the moved node",
		}
	var parent: Node = node.get_parent()
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var current_index := node.get_index()
	var target_index := target.get_index()
	var new_index := target_index + 1 if position == "after" else target_index
	if new_index == current_index:
		return {
			"ok": true,
			"changed": false,
			"undoable": false,
			"node_path": str(node.get_path()),
		}
	manager.create_action("gdcli: move node", UndoRedo.MERGE_DISABLE, parent)
	manager.add_do_method(parent, "move_child", node, new_index)
	manager.add_undo_method(parent, "move_child", node, current_index)
	manager.commit_action()
	parent.move_child(node, new_index)
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": str(node.get_path()),
	}

## 属性 set 通过 GdApiEditAction.commit_property ; 使用 VariantCodec 解码输入值
static func set_property(node_path: String, property: String, value: Variant) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var guard := check_property(node, property)
	if not guard.ok:
		return guard
	var decoded := VariantCodec.decode(value)
	if not decoded.ok:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": decoded.error,
		}
	# 直接使用节点 setter 提交手动编历的 do/undo,避开 EditorUndoRedoManager 在 headless 启动期可能挂起的兼容性.
	var manager := EditAction.undo_redo()
	if manager == null:
		return {"ok": false, "code": ErrorCodes.NOT_SUPPORTED, "error": "EditorUndoRedoManager unavailable"}
	var previous: Variant = node.get(property)
	manager.create_action("gdcli: set property")
	manager.add_do_property(node, StringName(property), decoded.value)
	manager.add_undo_property(node, StringName(property), previous)
	manager.commit_action()
	return {
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": lookup.node_path,
		"property": property,
		"value": VariantCodec.from_variant(decoded.value),
	}

## 读取属性,VariantCodec 编码为可序列化 JSON
static func get_property(node_path: String, property: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var guard := check_property(node, property)
	if not guard.ok:
		return guard
	if not (property in node):
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "property not readable: " + property,
		}
	var raw: Variant = node.get(property)
	return {
		"ok": true,
		"node_path": lookup.node_path,
		"property": property,
		"value": VariantCodec.from_variant(raw),
		"undoable": false,
	}

## 列出节点属性
static func list_properties(node_path: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var properties: Array = []
	for info in node.get_property_list():
		if info.usage & PROPERTY_USAGE_CATEGORY:
			continue
		var name: String = info.name
		if name.begins_with("_") and not (info.usage & PROPERTY_USAGE_EDITOR):
			continue
		properties.append({
			"name": name,
			"type": type_string(info.type),
			"usage": info.usage,
		})
	properties.sort_custom(func(a, b): return a.name < b.name)
	return {
		"ok": true,
		"node_path": lookup.node_path,
		"properties": properties,
		"undoable": false,
	}

## reset_property: 必须先存在 EditorInspector 句柄,这里使用 node.set(property, default) 并提交 do/undo
static func reset_property(node_path: String, property: String) -> Dictionary:
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var guard := check_property(node, property)
	if not guard.ok:
		return guard
	var previous: Variant = node.get(property)
	var defaults := ClassDB.class_get_property_default_value(node.get_class(), property)
	var result := EditAction.commit_property(node, StringName(property), defaults, "gdcli: reset property")
	if not result.ok:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": result.error}
	return {
		"ok": true,
		"changed": previous != defaults,
		"undoable": true,
		"node_path": lookup.node_path,
		"property": property,
		"value": VariantCodec.from_variant(defaults),
	}

static func revert_property(node_path: String, property: String) -> Dictionary:
	return reset_property(node_path, property)

## 列出当前场景节点的子节点摘要
## node_path 可缺省,缺省时使用 /root(编辑器场景根)
static func list_children(node_path: String) -> Dictionary:
	if node_path == "":
		node_path = "/root/Main"
	var lookup := find(node_path)
	if not lookup.ok:
		return lookup
	var node: Node = lookup.node
	var children: Array = []
	for child in node.get_children():
		children.append({
			"name": child.name,
			"path": _user_path_for(child),
			"type": child.get_class(),
		})
	return {
		"ok": true,
		"node_path": _user_path_for(node),
		"children": children,
		"undoable": false,
	}

## 将编辑器内部路径转换为面向用户的 `/root/<edited_root_name>/...` 路径
static func _user_path_for(node: Node) -> String:
	if not Engine.is_editor_hint():
		return str(node.get_path())
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		return str(node.get_path())
	if node == edited:
		return "/root/" + String(edited.name)
	# edited.get_path_to(node) 返回从 edited 到 node 的相对 NodePath
	var rel: NodePath = edited.get_path_to(node)
	var rel_str := str(rel).trim_prefix("/")
	if rel_str == "":
		return "/root/" + String(edited.name)
	return "/root/" + String(edited.name) + "/" + rel_str

## 选择节点到 EditorInterface selection
static func select(node_paths: Array) -> Dictionary:
	if node_paths.is_empty():
		EditorInterface.get_selection().clear()
		return {"ok": true, "changed": false, "undoable": false, "node_paths": []}
	var resolved: Array = []
	for raw in node_paths:
		var path := str(raw)
		var lookup := find(path)
		if not lookup.ok:
			return {
				"ok": false,
				"code": ErrorCodes.NOT_FOUND,
				"error": lookup.error,
			}
		resolved.append(lookup.node)
	EditorInterface.get_selection().clear()
	for n in resolved:
		EditorInterface.get_selection().add_node(n)
	return {
		"ok": true,
		"changed": true,
		"undoable": false,
		"node_paths": select_user_paths(resolved),
	}

static func select_user_paths(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		out.append(_user_path_for(n))
	return out
