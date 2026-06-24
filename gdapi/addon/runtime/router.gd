@tool
extends RefCounted

const GdApiRequest := preload("res://addons/gdapi/runtime/request.gd")
const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")
const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")

var _routes: Dictionary = {}
var _builtin_routes_handler: BuiltinRoutes

func scan(root_dir: String) -> void:
	_routes.clear()
	_routes["ping"] = BuiltinPing
	_builtin_routes_handler = BuiltinRoutes.new()
	_scan_dir(root_dir + "/editor", "")
	_scan_dir(root_dir + "/shared", "")
	var names: Array = _routes.keys()
	names.append("routes")
	names.sort()
	_builtin_routes_handler.set_route_names(names)

func count() -> int:
	return _routes.size() + 1

func _scan_dir(dir_path: String, prefix: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			var sub_prefix := (prefix + "/" + name) if prefix != "" else name
			_scan_dir(full, sub_prefix)
		elif name.ends_with(".gd") and not name.begins_with("_"):
			var route_name := name.substr(0, name.length() - 3)
			var key := (prefix + "/" + route_name) if prefix != "" else route_name
			var script: Script = load(full) as Script
			if script != null:
				_routes[key] = script
		name = dir.get_next()
	dir.list_dir_end()

func dispatch(req_dict: Dictionary, server) -> void:
	var id: int = req_dict["id"]
	var method: String = req_dict["method"]
	var path: String = req_dict["path"]

	if method != "POST":
		_reply_error(server, id, 405, "only POST is supported", "method_not_allowed")
		return

	var key: String = path.trim_prefix("/")

	if key == "routes":
		var req := GdApiRequest.new(req_dict)
		var res := GdApiResponse.new(server, id)
		_builtin_routes_handler.handle(req, res)
		return

	if not _routes.has(key):
		_reply_error(server, id, 404, "route not found: /" + key, "not_found")
		return

	var handler_script: Script = _routes[key]
	var handler = handler_script.new()

	var req := GdApiRequest.new(req_dict)
	var res := GdApiResponse.new(server, id)

	handler.handle(req, res)

func _reply_error(server, id: int, status: int, msg: String, code: String) -> void:
	var res := GdApiResponse.new(server, id)
	res.error(msg, code, status)
