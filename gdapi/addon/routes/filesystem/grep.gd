## filesystem/grep 路由: 文本搜索,返回 1-based 行/列匹配

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "filesystem/grep"

const MAX_ITEMS := 10000

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var root: String = req.get_body("root", "res://")
	var pattern: String = req.get_body("pattern", "")
	var glob: String = req.get_body("glob", "*")
	var case_sensitive: bool = req.get_body("case_sensitive", true)
	var offset: int = int(req.get_body("offset", 0))
	var limit: int = int(req.get_body("limit", 500))
	if pattern == "":
		res.error("pattern is required", ErrorCodes.MISSING_PARAM)
		return
	if limit < 1 or limit > MAX_ITEMS:
		res.error("limit out of bounds", ErrorCodes.INVALID_PARAM)
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
	_grep(checked.path, abs_dir, glob, pattern, case_sensitive, items)
	res.json({
		"ok": true,
		"items": items.slice(offset, offset + limit),
		"total": items.size(),
		"offset": offset,
		"limit": limit,
		"undoable": false,
	})


func _grep(res_path: String, abs_path: String, glob: String, pattern: String, case_sensitive: bool, out: Array) -> void:
	if out.size() >= MAX_ITEMS * 2:
		return
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
			_grep(sub_res, sub_abs, glob, pattern, case_sensitive, out)
		else:
			if _match_glob(name, glob):
				_search_in_file(sub_res, sub_abs, pattern, case_sensitive, out)
		name = dir.get_next()
	dir.list_dir_end()


func _search_in_file(res_path: String, abs_path: String, pattern: String, case_sensitive: bool, out: Array) -> void:
	var text := FileAccess.get_file_as_string(abs_path)
	if text.is_empty():
		return
	var search_text := pattern if case_sensitive else pattern.to_lower()
	var haystack := text if case_sensitive else text.to_lower()
	var line := 1
	var col := 1
	var i := 0
	while i < haystack.length():
		if haystack[i] == "\n":
			line += 1
			col = 1
			i += 1
			continue
		if haystack.substr(i, search_text.length()) == search_text:
			out.append({
				"path": res_path,
				"line": line,
				"column": col,
				"snippet": text.substr(i, min(80, text.length() - i)),
			})
			if out.size() >= MAX_ITEMS:
				return
			i += search_text.length()
			continue
		col += 1
		i += 1


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
		GdApiRouteDoc.make("在 root + glob 范围内搜索 pattern")
		.desc("递归扫描项目文件,返回 1-based 行/列匹配。文件大小限制 4 MiB;最多 10000 个匹配。")
		.param("root", "String", false, "起始目录", "res://")
		.param("pattern", "String", true, "字面搜索字符串")
		.param("glob", "String", false, "文件名 glob", "*")
		.param("case_sensitive", "bool", false, "是否区分大小写", "true")
		.param("offset", "int", false, "分页偏移", "0")
		.param("limit", "int", false, "1-10000", "500")
		.example("{\"root\":\"res://scripts\",\"pattern\":\"speed\",\"glob\":\"*.gd\"}")
		.returns("分页", {
			"ok": "bool",
			"items": "Array<{path,line,column,snippet}>",
			"total": "int",
			"offset": "int",
			"limit": "int",
			"undoable": "bool, false",
		})
	)
