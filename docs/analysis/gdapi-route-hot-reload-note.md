# GDAPI 路由热更新逻辑说明

## 背景

`gdapi/addon/plugin.gd` 中的 `_on_filesystem_changed()` 会在 Godot 编辑器检测到文件系统变化时重新扫描路由目录：

```gdscript
func _on_filesystem_changed() -> void:
	if _router:
		_router.scan("res://addons/gdapi/routes")
		print("[gdapi] routes reloaded (%d routes)" % _router.count())
```

## 当前结论

这段逻辑有保留价值，但它解决的不是 Godot 脚本热重载本身，而是 GDAPI 自己的路由表刷新问题。

Godot 编辑器通常会重新加载已变更的 GDScript，因此「已有 route handler 的 `handle()` 代码变更」很多情况下不需要 GDAPI 主动重新扫描也能生效。

但 Godot 不知道 `addons/gdapi/routes/**/*.gd` 与 HTTP 路由之间的映射规则，因此以下场景仍然需要 GDAPI 自己重新扫描路由目录：

- 新增 route 文件。
- 删除 route 文件。
- 改名 route 文件。
- 移动 route 文件。
- 更新 `/routes` 和 `/help` 这类依赖路由表的内置接口。

## 当前实现限制

现有 `Router.scan()` 主要处理新增和变更文件，尚未完整处理删除、改名或移动后的旧路由清理。

另外，`load(full)` 可能复用已有资源缓存。如果后续要更可靠地刷新 handler 脚本，可以考虑使用 Godot 4 的资源缓存刷新策略，例如 `ResourceLoader.load(..., CACHE_MODE_REPLACE)`。

## 暂定处理意见

暂时不改实现。

后续如果要完善热更新能力，应优先处理：

- 扫描时清理已不存在文件对应的旧路由。
- 评估是否需要强制刷新脚本资源缓存。
- 避免文件系统变化频繁触发时重复打印或重复扫描。
