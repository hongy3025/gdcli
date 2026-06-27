# Task 5: 验证和文档更新

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: 无
- Produces: 更新后的文档

- [ ] **Step 1: 运行所有测试确保功能正常**

Run: `cargo test --workspace`
Expected: 所有测试通过

- [ ] **Step 2: 运行 lint 和格式检查**

Run: `cargo clippy --workspace && cargo fmt --check`
Expected: 无警告，格式正确

- [ ] **Step 3: 更新 README.md 添加示例**

在 `README.md` 的 "Usage Examples" 部分添加：

```markdown
### Clap-Style Output

The `commands` and `command-help` subcommands now output in a clap-style format for better readability:

```bash
# List all commands in clap-style format
$ gdcli exec commands
Commands:
  ping                  健康检查
  editor/scene/save     保存场景
  shared/godot/version  获取 Godot 版本

# Get command help in clap-style format
$ gdcli exec command-help editor/scene/save
保存场景

Usage: gdcli exec editor/scene/save [OPTIONS]

Arguments:
  <scene_path>   场景文件路径 [required]
  [new_path]     另存为路径

Example:
  gdcli exec editor/scene/save --data '{"scene_path":"new.tscn"}'
```

For raw JSON output, use the `--json` flag:
```bash
$ gdcli --json exec commands
{"ok":true,"commands":[...]}
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add clap-style output examples to README"
```
