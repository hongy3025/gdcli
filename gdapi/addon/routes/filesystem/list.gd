## filesystem/list 路由: 列出项目目录

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/list"

const MAX_ITEMS := 5000

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "res://")
	var offset: int = int(req.get_body("offset", 0))
	var limit: int = int(req.get_body("limit", 500))
	if limit < 1 or limit > MAX_ITEMS:
		res.error("limit must be between 1 and " + str(MAX_ITEMS), ErrorCodes.INVALID_PARAM)
		return
	var checked := PathGuard.validate(path, "read")
	if not checked.ok:
		res.error(checked.error, checked.code, 400)
		return
	var abs_dir := ProjectSettings.globalize_path(checked.path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		res.error("directory does not exist: " + checked.path, ErrorCodes.NOT_FOUND, 404)
		return
	var all_items: Array = []
	_collect(checked.path, abs_dir, all_items)
	all_items.sort_custom(func(a, b): return a.path < b.path)
	var total := all_items.size()
	var slice := all_items.slice(offset, offset + limit)
	res.json({
		"ok": true,
		"path": checked.path,
		"items": slice,
		"total": total,
		"offset": offset,
		"limit": limit,
		"undoable": false,
	})


func _collect(res_path: String, abs_path: String, out: Array) -> void:
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
			_collect(sub_res, sub_abs, out)
		else:
			out.append({
				"path": sub_res,
				"name": name,
				"is_dir": false,
				"size": FileAccess.get_file_as_bytes(sub_abs).size(),
			})
		name = dir.get_next()
	dir.list_dir_end()


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出项目目录")
		.desc("分页排序,path 默认 res://。limit 不超过 5000。")
		.param("path", "String", false, "起始目录 res:// 路径", "res://")
		.param("offset", "int", false, "起始偏移", "0")
		.param("limit", "int", false, "限制项数 1-5000", "500")
		.example("{\"path\":\"res://scripts\",\"limit\":100}")
		.returns("分页", {
			"ok": "bool",
			"path": "String",
			"items": "Array<{path,name,is_dir,size}>",
			"total": "int",
			"offset": "int",
			"limit": "int",
			"undoable": "bool, false",
		})
	)
