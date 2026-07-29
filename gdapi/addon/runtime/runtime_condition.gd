## 运行时条件表达式 grammar interpreter
##
## 支持嵌套 and/or/not 布尔组合与 eq/ne/lt/lte/gt/gte/contains 比较。
## 不使用 Expression、str2var、动态编译,绝不执行任意代码。
##
## 操作对象可以是一个 literal,也可以是 {node_path, property} 占位符,
## 评估时从场景树读取相应属性值,避免任何 eval 类行为。

@tool
class_name GdApiRuntimeCondition
extends RefCounted

const COMPARISON_OPS := ["eq", "ne", "lt", "lte", "gt", "gte", "contains"]
const LOGICAL_OPS := ["and", "or", "not"]

## 评估一个条件节点
##
## @param node 字典:{"op":"and|or|not|...", "args"|"left"/"right":...}
## @return {ok:true, value:bool} 或 {ok:false, code, error}
static func evaluate(node: Variant) -> Dictionary:
	if typeof(node) != TYPE_DICTIONARY:
		return {"ok": false, "code": "invalid_param", "error": "condition must be an object"}
	var dict: Dictionary = node
	var op: String = String(dict.get("op", ""))
	if op.is_empty():
		return {"ok": false, "code": "invalid_param", "error": "condition.op is required"}
	if op in LOGICAL_OPS:
		return _eval_logical(dict, op)
	if op in COMPARISON_OPS:
		return _eval_compare(dict, op)
	return {"ok": false, "code": "not_supported", "error": "condition.op not supported: %s" % op}

## 评估布尔逻辑 op
static func _eval_logical(dict: Dictionary, op: String) -> Dictionary:
	match op:
		"and":
			var args: Array = dict.get("args", [])
			if args.size() < 2:
				return {"ok": false, "code": "invalid_param", "error": "and requires >= 2 args"}
			for arg in args:
				var r: Dictionary = evaluate(arg)
				if not bool(r.get("ok", false)):
					return r
				if not bool(r.get("value", false)):
					return {"ok": true, "value": false}
			return {"ok": true, "value": true}
		"or":
			var args: Array = dict.get("args", [])
			if args.size() < 2:
				return {"ok": false, "code": "invalid_param", "error": "or requires >= 2 args"}
			for arg in args:
				var r: Dictionary = evaluate(arg)
				if not bool(r.get("ok", false)):
					return r
				if bool(r.get("value", false)):
					return {"ok": true, "value": true}
			return {"ok": true, "value": false}
		"not":
			var args: Array = dict.get("args", [])
			if args.size() != 1:
				return {"ok": false, "code": "invalid_param", "error": "not requires exactly 1 arg"}
			var r: Dictionary = evaluate(args[0])
			if not bool(r.get("ok", false)):
				return r
			return {"ok": true, "value": not bool(r.get("value", false))}
	return {"ok": false, "code": "invalid_param", "error": "unsupported logical op: %s" % op}

## 评估比较 op,左右可以是 literal 或 {node_path, property}
static func _eval_compare(dict: Dictionary, op: String) -> Dictionary:
	if not dict.has("left") or not dict.has("right"):
		return {"ok": false, "code": "invalid_param", "error": "%s requires left and right" % op}
	var left: Variant = dict.get("left")
	var right: Variant = dict.get("right")
	var left_value: Dictionary = _resolve_value(left)
	if not bool(left_value.get("ok", false)):
		return left_value
	var right_value: Dictionary = _resolve_value(right)
	if not bool(right_value.get("ok", false)):
		return right_value
	var lv: Variant = left_value.value
	var rv: Variant = right_value.value
	match op:
		"eq":
			return {"ok": true, "value": _variants_equal(lv, rv)}
		"ne":
			return {"ok": true, "value": not _variants_equal(lv, rv)}
		"lt":
			return {"ok": true, "value": _variants_less(lv, rv)}
		"lte":
			return {"ok": true, "value": _variants_less(lv, rv) or _variants_equal(lv, rv)}
		"gt":
			return {"ok": true, "value": _variants_less(rv, lv)}
		"gte":
			return {"ok": true, "value": _variants_less(rv, lv) or _variants_equal(lv, rv)}
		"contains":
			return {"ok": true, "value": _contains(rv, lv)}
	return {"ok": false, "code": "invalid_param", "error": "unsupported compare op: %s" % op}

## 把 literal 或 {node_path, property} 解析为 Variant
static func _resolve_value(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY:
		var dict: Dictionary = value
		if dict.has("node_path") and dict.has("property"):
			var node_path: String = String(dict.node_path)
			var property: String = String(dict.property)
			var tree := Engine.get_main_loop() as SceneTree
			if tree == null:
				return {"ok": false, "code": "conflict", "error": "scene tree is unavailable"}
			var node: Node = tree.root.get_node_or_null(NodePath(node_path))
			if node == null:
				return {"ok": false, "code": "not_found", "error": "node not found: %s" % node_path}
			if property.is_empty() or not _has_property(node, property):
				return {"ok": false, "code": "not_found", "error": "property does not exist: %s" % property}
			return {"ok": true, "value": node.get(property)}
	return {"ok": true, "value": value}

static func _has_property(node: Node, property: String) -> bool:
	for info in node.get_property_list():
		if String(info.name) == property:
			return true
	return false

static func _variants_equal(a: Variant, b: Variant) -> bool:
	if _is_numeric(a) and _is_numeric(b):
		return is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return false
	if a is Vector2 and b is Vector2:
		return (a - b).length() < 0.001
	if a is Vector3 and b is Vector3:
		return (a - b).length() < 0.001
	return a == b

static func _variants_less(a: Variant, b: Variant) -> bool:
	if _is_numeric(a) and _is_numeric(b):
		return float(a) < float(b) and not is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return str(a) < str(b)
	if a is Vector2 and b is Vector2:
		return a.length() < b.length()
	if a is Vector3 and b is Vector3:
		return a.length() < b.length()
	return a < b

static func _contains(container: Variant, target: Variant) -> bool:
	if container is Array:
		var arr: Array = container
		for element in arr:
			if _variants_equal(element, target):
				return true
		return false
	if container is String:
		return String(container).contains(String(target))
	if container is Dictionary:
		return container.has(target)
	return false

static func _is_numeric(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
