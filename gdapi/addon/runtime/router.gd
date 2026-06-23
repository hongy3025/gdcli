@tool
extends RefCounted

const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")

# path (无前导 /) → Script
var _routes: Dictionary = {}
var _builtin_routes_handler: BuiltinRoutes

func scan(root_dir: String) -> void:
    _routes.clear()
    # 内置路由
    _routes["ping"] = BuiltinPing
    _builtin_routes_handler = BuiltinRoutes.new()

    _scan_dir(root_dir + "/editor", "")
    _scan_dir(root_dir + "/shared", "")

    var names: Array = _routes.keys()
    names.append("routes")  # 把 routes 自身也算进去
    names.sort()
    _builtin_routes_handler.set_route_names(names)

func count() -> int:
    return _routes.size() + 1  # +1 for /routes

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
            var route_name := name.substr(0, name.length() - 3)  # strip .gd
            var key := (prefix + "/" + route_name) if prefix != "" else route_name
            var script: Script = load(full) as Script
            if script != null:
                _routes[key] = script
        name = dir.get_next()
    dir.list_dir_end()

func dispatch(req: Dictionary, server) -> void:
    var id: int = req["id"]
    var method: String = req["method"]
    var path: String = req["path"]

    if method != "POST":
        _reply(server, id, 405, {"error": "only POST is supported"})
        return

    var key: String = path.trim_prefix("/")

    # /routes 特殊处理
    if key == "routes":
        var result := _builtin_routes_handler.handle({})
        var status := _builtin_routes_handler.status_code(result)
        _reply(server, id, status, result)
        return

    if not _routes.has(key):
        _reply(server, id, 404, {
            "error": "route not found: /" + key,
            "available": _routes.keys(),
        })
        return

    var handler_script: Script = _routes[key]
    var handler = handler_script.new()

    # 解析 body
    var params: Dictionary = {}
    var body: PackedByteArray = req["body"]
    if body.size() > 0:
        var text := body.get_string_from_utf8()
        var parsed = JSON.parse_string(text)
        if typeof(parsed) != TYPE_DICTIONARY:
            _reply(server, id, 400, {"error": "body must be a JSON object"})
            return
        params = parsed

    var result = handler.handle(params)
    if typeof(result) != TYPE_DICTIONARY:
        result = {"error": "handler must return Dictionary, got " + str(typeof(result))}
    var status: int = handler.status_code(result)
    _reply(server, id, status, result)

func _reply(server, id: int, status: int, body: Dictionary) -> void:
    var json := JSON.stringify(body)
    var headers := {"Content-Type": "application/json; charset=utf-8"}
    server.send_response(id, status, headers, json.to_utf8_buffer())
