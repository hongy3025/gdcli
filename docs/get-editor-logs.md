在 Godot 4 中，官方并没有提供直接的 API（如 `EditorInterface.get_output_log()`）来获取输出面板（Output Panel）的内容。

要实现这个功能，最有效的方法是**“遍历编辑器本身的场景树”**。因为 Godot 编辑器本身也是用 Godot 引擎开发的，所以我们可以通过代码找到存放日志的 `RichTextLabel` 控件并读取它的内容。

以下是实现步骤和代码示例：

### 1. 插件结构
创建插件文件夹 `addons/output_reader/`，包含：
- `plugin.cfg`
- `output_reader.gd` (脚本)

### 2. 编写 `plugin.gd`

核心逻辑是通过 `EditorInterface.get_base_control()` 获取编辑器根节点，然后递归查找类名为 `EditorLog` 内部的 `RichTextLabel`。

```gdscript
@tool
extends EditorPlugin

var output_copy_button: Button

func _enter_tree():
	# 添加一个按钮到编辑器顶部，点击时读取日志
	output_copy_button = Button.new()
	output_copy_button.text = "读取输出日志"
	output_copy_button.pressed.connect(_on_read_log_pressed)
	add_control_to_container(CONTAINER_TOOLBAR, output_copy_button)

func _exit_tree():
	# 移除按钮
	remove_control_from_container(CONTAINER_TOOLBAR, output_copy_button)
	output_copy_button.queue_free()

func _on_read_log_pressed():
	var log_label = _find_output_log_label(EditorInterface.get_base_control())
	
	if log_label:
		var all_text = log_label.text
		print("--- 成功读取到日志 (长度: ", all_text.length(), ") ---")
		# 你可以在这里处理字符串，比如保存到文件或分析关键词
		_save_log_to_file(all_text)
	else:
		printerr("未能找到输出面板的 RichTextLabel 控件")

# 递归寻找输出面板中的 RichTextLabel
func _find_output_log_label(node: Node) -> RichTextLabel:
	# 在 Godot 4 中，输出面板的类名通常是 'EditorLog'
	# 它的内部结构包含一个 RichTextLabel 用于显示文字
	if node.get_class() == "EditorLog":
		# 遍历 EditorLog 的子节点寻找 RichTextLabel
		return _find_rich_text_recursive(node)
	
	for child in node.get_children():
		var found = _find_output_log_label(child)
		if found:
			return found
	return null

func _find_rich_text_recursive(node: Node) -> RichTextLabel:
	if node is RichTextLabel:
		return node
	for child in node.get_children():
		var res = _find_rich_text_recursive(child)
		if res:
			return res
	return null

func _save_log_to_file(content: String):
	var path = "user://editor_output_dump.txt"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		print("日志已导出至: ", ProjectSettings.globalize_path(path))
```

### 3. 实现原理详解

1.  **EditorInterface.get_base_control()**: 这是编辑器主窗口的根节点。通过它，我们可以访问编辑器界面的所有 UI 元素（按钮、面板、树列表等）。
2.  **EditorLog 类**: Godot 源码中，输出面板的实现类叫 `EditorLog`。虽然它在 GDScript 中不是公开暴露的类，但我们可以通过 `get_class()` 识别它。
3.  **RichTextLabel**: `EditorLog` 内部使用了一个 `RichTextLabel` 来承载所有的文字输出。获取到这个对象后，通过 `.text` 属性就能拿到所有日志。
4.  **实时性**: 如果你需要实时监听日志变化，可以在 `_process` 中轮询检查 `.text` 的长度，或者寻找更深层的信号（但通常轮询或手动触发更稳妥）。

### 4. 注意事项与局限性

*   **版本兼容性**: Godot 的内部 UI 结构可能会在次要版本（如 4.4 到 4.5）中发生变化。如果有一天代码失效了，你可以使用编辑器自带的 **"查看场景树"** 功能（或插件开发工具）重新定位 `EditorLog` 的位置。
*   **富文本标签**: `RichTextLabel.text` 获取的是带有 BBCode 标签的原始文本（例如 `[color=red]...[/color]`）。如果你只需要纯文本，可以使用 `log_label.get_parsed_text()`。
*   **性能**: 日志可能非常大（几万行），频繁读取整个 `text` 字符串可能会导致编辑器卡顿。建议只在需要时触发。

### 5. 进阶：如何找到那个节点？
如果你想自己研究编辑器结构，可以在插件里运行这段代码，它会把编辑器所有的节点名打印出来：
```gdscript
func dump_editor_tree(node: Node, indent: int):
	print("  ".repeat(indent), node.name, " (", node.get_class(), ")")
	for child in node.get_children():
		dump_editor_tree(child, indent + 1)
```
你会发现 `EditorLog` 通常位于一个 `VBoxContainer` 下，属于底栏面板的一部分。