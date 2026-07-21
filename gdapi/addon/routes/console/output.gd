## 控制台日志尾读路由处理器
##
## 提供读取 Godot 编辑器 Output 面板内容的 API 端点。
## 通过遍历编辑器场景树找到 EditorLog 内的 RichTextLabel，读取其文本。
## 支持基于字符偏移量的增量读取。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 缓存 EditorLog 内的 RichTextLabel 引用，避免每次请求都遍历场景树
var _cached_rtl: RichTextLabel = null

## 处理日志尾读请求
##
## 从编辑器 Output 面板的 RichTextLabel 读取文本内容。
## @param req 请求对象，包含可选的 offset（字符偏移量）和 limit（最大行数）
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var offset: int = req.get_body("offset", 0)
	var limit: int = req.get_body("limit", 200)

	# 查找 EditorLog 内的 RichTextLabel
	var rtl := _find_output_rtl()
	if rtl == null:
		res.error("editor output log not found", "not_found", 404)
		return

	var full_text: String = rtl.get_parsed_text()
	var text_len: int = full_text.length()

	# 偏移量超出文本长度则从头读取（编辑器日志被清空等情况）
	if offset > text_len:
		offset = 0

	var lines: Array = []
	var new_offset: int = offset
	while lines.size() < limit and new_offset < text_len:
		var next_newline: int = full_text.find("\n", new_offset)
		if next_newline == -1:
			lines.append(full_text.substr(new_offset))
			new_offset = text_len
		else:
			lines.append(full_text.substr(new_offset, next_newline - new_offset))
			new_offset = next_newline + 1

	var eof: bool = new_offset >= text_len

	res.json({
		"ok": true,
		"lines": lines,
		"offset": new_offset,
		"eof": eof,
	})
## 查找 EditorLog 内的 RichTextLabel
##
## 优先使用缓存引用；若无效则遍历编辑器场景树查找。
## @return RichTextLabel 节点，未找到时返回 null
func _find_output_rtl() -> RichTextLabel:
	# 验证缓存引用是否仍然有效
	if _cached_rtl != null and is_instance_valid(_cached_rtl):
		return _cached_rtl

	var base := EditorInterface.get_base_control()
	if base == null:
		return null

	_cached_rtl = _search_editor_log_rtl(base)
	return _cached_rtl

## 递归遍历场景树，查找 EditorLog 内的 RichTextLabel
##
## @param node 当前遍历节点
## @return RichTextLabel 节点，未找到时返回 null
func _search_editor_log_rtl(node: Node) -> RichTextLabel:
	if node.get_class() == "EditorLog":
		return _find_rtl_recursive(node)
	for child in node.get_children():
		var found := _search_editor_log_rtl(child)
		if found != null:
			return found
	return null

## 在指定节点及其子节点中查找 RichTextLabel
##
## @param node 当前遍历节点
## @return RichTextLabel 节点，未找到时返回 null
func _find_rtl_recursive(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node
	for child in node.get_children():
		var res := _find_rtl_recursive(child)
		if res != null:
			return res
	return null

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取编辑器控制台日志")
		.desc("从编辑器 Output 面板读取日志内容；包含编辑器启动信息、插件消息和运行场景输出；支持基于字符偏移量的增量拉取")
		.param("offset", "int", false, "字符偏移量，上次响应返回的 offset 值", 0)
		.param("limit", "int", false, "最大返回行数", 200)
		.example("{\"offset\":0,\"limit\":50}")
		.returns("日志内容和分页信息", {
			"ok": "bool",
			"lines": "Array[String], 日志行数组（纯文本）",
			"offset": "int, 下次请求应传入的字符偏移量",
			"eof": "bool, 是否已到内容末尾",
		})
	)
