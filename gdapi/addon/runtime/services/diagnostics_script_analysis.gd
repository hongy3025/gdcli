@tool
extends RefCounted


## A lexical scan, not a GDScript parser: strings are opaque tokens and comments
## are discarded. Only literal paths and self/local declarations are resolved.
static func scan(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	var tokens := _tokens(source)
	var references: Array = []
	var declarations: Array = []
	var functions: Dictionary = {}
	var signals: Dictionary = {}
	for i in range(tokens.size() - 1):
		if tokens[i].kind != "identifier":
			continue
		var keyword: String = tokens[i].value
		if keyword in ["func", "signal", "class_name"] and tokens[i + 1].kind == "identifier":
			var name: String = tokens[i + 1].value
			var item := _ref(path, tokens[i].line, keyword, name, "resolved")
			declarations.append(item)
			if keyword == "func":
				functions[name] = true
			elif keyword == "signal":
				signals[name] = true
	for i in range(tokens.size()):
		var token: Dictionary = tokens[i]
		if token.kind != "identifier":
			continue
		var name: String = token.value
		var previous := _value(tokens, i - 1)
		var following := _value(tokens, i + 1)
		if name == "extends":
			var next := _token(tokens, i + 1)
			var value := String(next.get("value", ""))
			var ref := _ref(path, token.line, "extends", value, "resolved")
			ref["target_kind"] = "file" if next.get("kind") == "string" else "class"
			if ref.target_kind == "file":
				ref.target = _preload_path(path, value)
			references.append(ref)
			continue
		if name == "class_name" and following != "":
			references.append(_ref(path, token.line, "class_name", following, "resolved"))
			continue
		if following != "(" or previous in ["func", "signal"]:
			continue
		var args := _arguments(tokens, i + 1)
		if name in ["load", "preload"] and previous != ".":
			var literal := _literal(args, 0)
			var resource_target := (
				_preload_path(path, literal) if name == "preload" else _load_path(literal)
			)
			var ref := _ref(
				path,
				token.line,
				name,
				resource_target,
				"resolved" if not literal.is_empty() else "unknown"
			)
			if literal.is_empty():
				ref["reason"] = "resource path is computed at runtime"
			references.append(ref)
		elif name in ["emit_signal", "connect", "emit"]:
			var flow := _flow(path, token.line, tokens, i, args, functions, signals)
			references.append(flow)
		elif (
			name
			not in [
				"if",
				"elif",
				"while",
				"for",
				"match",
				"assert",
				"await",
				"Callable",
				"Signal",
				"super"
			]
		):
			var status := "resolved" if functions.has(name) and previous != "." else "unknown"
			var ref := _ref(path, token.line, "function_reference", name, status)
			ref["source"] = _receiver(tokens, i) if previous == "." else "self"
			if ref.source == "self" and functions.has(name):
				ref.status = "resolved"
			if ref.status == "unknown":
				ref["reason"] = "built-in, inherited, external or runtime callable; not type-inferred"
			references.append(ref)
	return {"references": references, "declarations": declarations}


static func _flow(
	path: String,
	line: int,
	tokens: Array,
	index: int,
	args: Array,
	functions: Dictionary,
	signals: Dictionary
) -> Dictionary:
	var operation := String(tokens[index].value)
	var receiver := _receiver(tokens, index)
	var signal_name := (
		_literal(args, 0)
		if operation == "emit_signal"
		else receiver.get_slice(".", receiver.get_slice_count(".") - 1)
	)
	var source := "self"
	if operation == "connect" and receiver != "self":
		if args.size() > 0 and _literal(args, 0) != "":
			signal_name = _literal(args, 0)
			source = receiver
		else:
			source = receiver.trim_suffix("." + signal_name) if receiver.contains(".") else "self"
	elif operation == "emit":
		source = receiver.trim_suffix("." + signal_name) if receiver.contains(".") else "self"
	elif operation == "emit_signal":
		source = receiver
	var ref := _ref(path, line, "connect" if operation == "connect" else "emit", "", "unknown")
	ref.merge({"signal": signal_name, "source": source, "method": "", "scene": ""})
	if source == "self" and signals.has(signal_name):
		ref.status = "resolved"
	if operation == "connect":
		var arg_index := 1 if _literal(args, 0) != "" else 0
		var callable_arg: Array = args[arg_index] if arg_index < args.size() else []
		var callable := _callable(callable_arg)
		ref.target = callable.target
		ref.method = callable.method
		if (
			ref.status == "resolved"
			and callable.target == "self"
			and functions.has(callable.method)
		):
			ref.status = "resolved"
		else:
			ref.status = "unknown"
	if ref.status == "unknown":
		ref["reason"] = "signal, receiver or callable cannot be statically resolved"
	return ref


static func _callable(tokens: Array) -> Dictionary:
	if tokens.size() == 1 and tokens[0].kind == "identifier":
		return {"target": "self", "method": tokens[0].value}
	if tokens.size() == 3 and _value(tokens, 0) == "self" and _value(tokens, 1) == ".":
		return {"target": "self", "method": tokens[2].value}
	if _value(tokens, 0) == "Callable" and _value(tokens, 1) == "(":
		var args := _arguments(tokens, 1)
		if args.size() == 2 and args[0].size() == 1:
			return {"target": _value(args[0], 0), "method": _literal(args, 1)}
	return {"target": "", "method": ""}


static func _receiver(tokens: Array, index: int) -> String:
	if _value(tokens, index - 1) != ".":
		return "self"
	var cursor := index - 2
	var pieces: Array[String] = []
	while cursor >= 0 and _token(tokens, cursor).get("kind") == "identifier":
		pieces.push_front(_value(tokens, cursor))
		if _value(tokens, cursor - 1) != ".":
			break
		cursor -= 2
	if pieces.is_empty():
		return "<dynamic>"
	if cursor >= 0 and _token(tokens, cursor).get("kind") != "identifier":
		pieces.push_front("<dynamic>")
	return ".".join(pieces)


static func _arguments(tokens: Array, opening: int) -> Array:
	var args: Array = []
	var current: Array = []
	var depth := 0
	for i in range(opening + 1, tokens.size()):
		if tokens[i].kind != "punctuation":
			current.append(tokens[i])
			continue
		var value := _value(tokens, i)
		if value == ")" and depth == 0:
			if not current.is_empty():
				args.append(current)
			return args
		if value == "," and depth == 0:
			args.append(current)
			current = []
			continue
		if value in ["(", "[", "{"]:
			depth += 1
		elif value in [")", "]", "}"]:
			depth -= 1
		current.append(tokens[i])
	return args


static func _literal(args: Array, index: int) -> String:
	if index < args.size() and args[index].size() == 1 and args[index][0].kind == "string":
		return String(args[index][0].value)
	return ""


static func _preload_path(script_path: String, value: String) -> String:
	if (
		value.is_empty()
		or value.begins_with("res://")
		or value.begins_with("user://")
		or value.begins_with("uid://")
	):
		return value
	return script_path.get_base_dir().path_join(value).simplify_path()


static func _load_path(value: String) -> String:
	if (
		value.is_empty()
		or value.begins_with("res://")
		or value.begins_with("user://")
		or value.begins_with("uid://")
	):
		return value
	return ("res://" + value).simplify_path()


static func _ref(
	path: String, line: int, kind: String, target: String, status: String
) -> Dictionary:
	return {"path": path, "line": line, "kind": kind, "target": target, "status": status}


static func _value(tokens: Array, index: int) -> String:
	return String(_token(tokens, index).get("value", ""))


static func _token(tokens: Array, index: int) -> Dictionary:
	return tokens[index] if index >= 0 and index < tokens.size() else {}


static func _tokens(source: String) -> Array:
	var result: Array = []
	var i := 0
	var line := 1
	while i < source.length():
		var c := source[i]
		if c == "\n":
			line += 1
			i += 1
			continue
		if c in [" ", "\t", "\r"]:
			i += 1
			continue
		if c == "#":
			while i < source.length() and source[i] != "\n":
				i += 1
			continue
		if c == "&" and i + 1 < source.length() and source[i + 1] in ['"', "'"]:
			i += 1
			continue
		var raw := false
		if c in ["r", "R"] and i + 1 < source.length() and source[i + 1] in ['"', "'"]:
			raw = true
			i += 1
			c = source[i]
		if c == "&" and i + 1 < source.length() and source[i + 1] in ['"', "'"]:
			i += 1
			c = source[i]
		if c in ['"', "'"]:
			var start_line := line
			var triple := source.substr(i, 3) == c + c + c
			var delimiter := c + c + c if triple else c
			i += delimiter.length()
			var value := ""
			while i < source.length() and source.substr(i, delimiter.length()) != delimiter:
				if not raw and source[i] == "\\" and i + 1 < source.length():
					i += 1
					var escaped := source[i]
					if escaped == "u" and i + 4 < source.length():
						value += String.chr(source.substr(i + 1, 4).hex_to_int())
						i += 4
					elif escaped == "U" and i + 8 < source.length():
						value += String.chr(source.substr(i + 1, 8).hex_to_int())
						i += 8
					else:
						value += {"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped)
				else:
					value += source[i]
				if source[i] == "\n":
					line += 1
				i += 1
			i += delimiter.length()
			result.append({"kind": "string", "value": value, "line": start_line})
			continue
		var code := c.unicode_at(0)
		if c == "_" or code >= 128 or (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
			var start := i
			i += 1
			while i < source.length():
				var n := source[i].unicode_at(0)
				if (
					source[i] != "_"
					and n < 128
					and not (n >= 65 and n <= 90)
					and not (n >= 97 and n <= 122)
					and not (n >= 48 and n <= 57)
				):
					break
				i += 1
			result.append(
				{"kind": "identifier", "value": source.substr(start, i - start), "line": line}
			)
			continue
		result.append({"kind": "punctuation", "value": c, "line": line})
		i += 1
	return result
