## node/set 路由: 批量设置多个属性接 UndoRedo

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")

const ROUTE := "node/set"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var node_path: String = req.get_body("node_path", "")
	var properties: Dictionary = req.get_body("properties", {})
	if node_path == "":
		res.error("node_path is required", "missing_param")
		return
	if properties.is_empty():
		res.error("properties must be a non-empty dictionary", "missing_param")
		return
	var lookup := NodeEditor.find(node_path)
	if not lookup.ok:
		res.error(lookup.error, lookup.code, 404)
		return
	var node: Node = lookup.node
	# 预校验: 任一字段无效则整体拒绝
	for key in properties.keys():
		var guard := NodeEditor.check_property(node, key)
		if not guard.ok:
			res.error("property rejected: " + key, guard.code, 400)
			return
		var decoded := VariantCodec.decode(properties[key])
		if not decoded.ok:
			res.error("invalid value for " + key + ": " + decoded.error, ErrorCodes.INVALID_PARAM)
			return
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error("EditorUndoRedoManager unavailable", ErrorCodes.NOT_SUPPORTED)
		return
	manager.create_action("gdcli: set properties", UndoRedo.MERGE_DISABLE, node)
	var applied: Dictionary = {}
	for key in properties.keys():
		var value = VariantCodec.decode(properties[key]).value
		var previous: Variant = node.get(key)
		manager.add_do_property(node, StringName(key), value)
		manager.add_undo_property(node, StringName(key), previous)
		applied[key] = VariantCodec.from_variant(value)
	manager.commit_action()
	res.json({
		"ok": true,
		"changed": true,
		"undoable": true,
		"node_path": lookup.node_path,
		"applied": applied,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("批量原子设置节点属性接 UndoRedo")
		.desc("所有字段一次性校验,任一字段无效则整体拒绝。提交单个 UndoRedo action 便于一次撤销。")
		.param("node_path", "String", true, "节点绝对路径")
		.param("properties", "Dictionary<String,Variant>", true, "属性名->属性值,值通过 VariantCodec 解码")
		.example("{\"node_path\":\"/root/Main/Player\",\"properties\":{\"position\":{\"type\":\"Vector2\",\"value\":[24,32]}}}")
		.returns("设置结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, true",
			"node_path": "String",
			"applied": "Dictionary<String,Variant>, 已应用值的编码表示",
		})
	)
