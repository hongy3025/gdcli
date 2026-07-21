## filesystem/search 路由: glob 风格查找

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/search"

const MAX_ITEMS := 1000

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var root: String = req.get_body("root", "res://")
	var pattern: String = req.get_body("glob", "*")
	var offset: int = int(req.get_body("offset", 0))
	var limit: int = int(req.get_body("limit", 200))
	if limit < 1 or limit > MAX_ITEMS:
		res.error("limit must be 1-" + str(MAX_ITEMS), ErrorCodes.INVALID_PARAM)
		return
	var checked := PathGuard.validate(root, "read")
	if not checked.ok:
		res.error(checked.error, checked.code, 400)
		return
	var abs_dir := ProjectSettings.globalize_path(checked.path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		res.error("directory not found: " + checked.path, ErrorCodes.NOT_FOUND, 404)
		return
	var items: Array = []
	_collect(checked.path, abs_dir, pattern, items)
	items.sort()
	var total := items.size()
	res.json({
		"ok": true,
		"root": checked.path,
		"glob": pattern,
		"items": items.slice(offset, offset + limit),
		"total": total,
		"offset": offset,
		"limit": limit,
		"undoable": false,
	})


func _collect(res_path: String, abs_path: String, pattern: String, out: Array) -> void:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var sub_res := res_path.trim_suffix("/") + "/" + name
		var sub_abs := abs_path.trim_suffix("/") + "/" + name
		if dir.current_is_dir():
			_collect(sub_res, sub_abs, pattern, out)
		else:
			if _match_glob(name, pattern):
				out.append(sub_res)
		name = dir.get_next()
	dir.list_dir_end()


static func _match_glob(name: String, pattern: String) -> bool:
	var regex := "^" + _glob_to_regex(pattern) + "$"
	var r := RegEx.new()
	return r.compile(regex) == OK and r.search(name) != null


static func _glob_to_regex(glob: String) -> String:
	var out := ""
	for c in glob:
		match c:
			"*": out += "[^/]*"
			"?": out += "[^/]"
			".": out += "\\."
			_:
				if c in "+()[]{}\\^$|":
					out += "\\" + c
				else:
					out += c
	return out


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("按 glob 模式查找项目文件")
		.desc("递归扫描 root + glob,默认 root=res://,glob=*。")
		.param("root", "String", false, "起始目录", "res://")
		.param("glob", "String", false, "文件名 glob 模式,支持 * ?", "*")
		.param("offset", "int", false, "分页偏移", "0")
		.param("limit", "int", false, "1-1000", "200")
		.example("{\"root\":\"res://scripts\",\"glob\":\"*.gd\",\"limit\":50}")
		.returns("分页", {
			"ok": "bool",
			"root": "String",
			"glob": "String",
			"items": "Array<String>, 文件路径",
			"total": "int",
			"offset": "int",
			"limit": "int",
			"undoable": "bool, false",
		})
	)
