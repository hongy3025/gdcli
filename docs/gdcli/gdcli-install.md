# gdcli install — 安装编辑器插件

将 gdapi 插件安装到目标 Godot 项目，自动修改 `project.godot` 启用插件。

```bash
gdcli install --project /path/to/project
```

| 选项 | 说明 |
|------|------|
| `--force` | 覆盖已有安装 |
| `--no-enable` | 不修改 `project.godot` 启用插件 |

安装效果：复制 gdapi 插件文件到 `addons/gdapi/`，在 `project.godot` 中添加插件引用。
安装后需在 Godot 编辑器中打开项目以激活插件。