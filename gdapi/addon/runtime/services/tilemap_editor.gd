@tool
class_name GdApiTilemapEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

const CELL_LIMIT := 32767
const MAX_FILL_CELLS := 4096


static func layer(path: String) -> Dictionary:
	var root := SceneEditor.current_root()
	if root == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	var node := root.get_node_or_null(NodePath(path))
	if not node is TileMapLayer:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "TileMapLayer not found"}
	return {"ok": true, "layer": node}


static func coordinate(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not raw.has("x") or not raw.has("y"):
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "coordinate must contain x and y"
		}
	var cell := Vector2i(int(raw.x), int(raw.y))
	if abs(cell.x) > CELL_LIMIT or abs(cell.y) > CELL_LIMIT:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "coordinate exceeds signed 16-bit range"
		}
	return {"ok": true, "cell": cell}


static func info(path: String) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	var target: TileMapLayer = found.layer
	return {
		"ok": true,
		"path": path,
		"used_cell_count": target.get_used_cells().size(),
		"undoable": false
	}


static func get_cell(path: String, raw_cell: Variant) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	var parsed := coordinate(raw_cell)
	if not parsed.ok:
		return parsed
	return _cell_record(found.layer, parsed.cell)


static func set_cell(
	path: String, raw_cell: Variant, source_id: int, raw_atlas: Variant, alternative: int = 0
) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	var parsed := coordinate(raw_cell)
	if not parsed.ok:
		return parsed
	var atlas := coordinate(raw_atlas)
	if not atlas.ok:
		return atlas
	if source_id < -1 or alternative < 0:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "invalid source_id or alternative"
		}
	return _commit_cell(
		found.layer, parsed.cell, source_id, atlas.cell, alternative, "gdcli: set tilemap cell"
	)


static func fill_rect(
	path: String,
	raw_from: Variant,
	raw_to: Variant,
	source_id: int,
	raw_atlas: Variant,
	alternative: int = 0
) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	var first := coordinate(raw_from)
	var last := coordinate(raw_to)
	var atlas := coordinate(raw_atlas)
	if not first.ok:
		return first
	if not last.ok:
		return last
	if not atlas.ok:
		return atlas
	var min_x := min(first.cell.x, last.cell.x)
	var max_x := max(first.cell.x, last.cell.x)
	var min_y := min(first.cell.y, last.cell.y)
	var max_y := max(first.cell.y, last.cell.y)
	var count: int = int((max_x - min_x + 1) * (max_y - min_y + 1))
	if count > MAX_FILL_CELLS:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "rectangle exceeds maximum cell count"
		}
	var cells: Array = []
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			cells.append(Vector2i(x, y))
	return _commit_cells(
		found.layer, cells, source_id, atlas.cell, alternative, "gdcli: fill tilemap rectangle"
	)


static func clear(path: String, force: bool) -> Dictionary:
	if not force:
		return {
			"ok": false,
			"code": ErrorCodes.UNSAFE_OPERATION,
			"error": "tilemap/layer/clear requires force:true"
		}
	var found := layer(path)
	if not found.ok:
		return found
	var target: TileMapLayer = found.layer
	var cells: Array = target.get_used_cells()
	return _commit_cells(target, cells, -1, Vector2i(-1, -1), 0, "gdcli: clear tilemap layer")


static func used_cells(path: String) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	var cells: Array = found.layer.get_used_cells()
	cells.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	var out: Array = []
	for cell in cells:
		out.append({"x": cell.x, "y": cell.y})
	return {"ok": true, "cells": out, "undoable": false}


static func _cell_record(target: TileMapLayer, cell: Vector2i) -> Dictionary:
	return {
		"ok": true,
		"cell": {"x": cell.x, "y": cell.y},
		"source_id": target.get_cell_source_id(cell),
		"atlas_coords": _point(target.get_cell_atlas_coords(cell)),
		"alternative": target.get_cell_alternative_tile(cell),
		"undoable": false
	}


static func _point(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}


static func _commit_cell(
	target: TileMapLayer,
	cell: Vector2i,
	source_id: int,
	atlas: Vector2i,
	alternative: int,
	action: String
) -> Dictionary:
	var old := [
		target.get_cell_source_id(cell),
		target.get_cell_atlas_coords(cell),
		target.get_cell_alternative_tile(cell)
	]
	var manager := EditAction.undo_redo()
	if manager == null:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "EditorUndoRedoManager unavailable"
		}
	var holder := GdApiTilemapEditor.new()
	manager.create_action(action, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_method(holder, "apply_cell", target, cell, source_id, atlas, alternative)
	manager.add_undo_method(holder, "apply_cell", target, cell, old[0], old[1], old[2])
	manager.commit_action()
	return {"ok": true, "changed": true, "undoable": true, "cell": _point(cell)}


static func _commit_cells(
	target: TileMapLayer,
	cells: Array,
	source_id: int,
	atlas: Vector2i,
	alternative: int,
	action: String
) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_SUPPORTED,
			"error": "EditorUndoRedoManager unavailable"
		}
	var holder := GdApiTilemapEditor.new()
	manager.create_action(action, UndoRedo.MERGE_DISABLE, target)
	for cell in cells:
		var old := [
			target.get_cell_source_id(cell),
			target.get_cell_atlas_coords(cell),
			target.get_cell_alternative_tile(cell)
		]
		manager.add_do_method(holder, "apply_cell", target, cell, source_id, atlas, alternative)
		manager.add_undo_method(holder, "apply_cell", target, cell, old[0], old[1], old[2])
	manager.commit_action()
	return {"ok": true, "changed": not cells.is_empty(), "undoable": true, "count": cells.size()}


func apply_cell(
	target: TileMapLayer, cell: Vector2i, source_id: int, atlas: Vector2i, alternative: int
) -> void:
	target.set_cell(cell, source_id, atlas, alternative)
