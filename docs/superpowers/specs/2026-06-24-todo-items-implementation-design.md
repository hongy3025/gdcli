# TODO 项实现设计文档

- **日期**：2026-06-24
- **状态**：待批准
- **版本**：0.2.0 → 0.3.0（计划）

## 1. 背景与目标

基于 `docs/handoff.md` 中记录的遗留 TODO 项，本次迭代实现以下功能：

**实现范围**（用户选择）：
- #3 HTTP header 注入防护
- #5 LSP 端口自动重映射
- #6 gdapi 路由热重载
- #7 gdapi 认证机制
- #8 HTTP 边界测试补充
- #9 project.godot 解析健壮性
- #11 PackedByteArray 构造优化
- #13 版本号统一管理
- #14 dead_code 警告清理
- 扩展：gdcli status 同时检测 exec 和 lsp 连通性

**排除项**：
- #1 端到端验证（需要本地 Godot 环境）
- #2 CI/CD 流水线（本次不做）
- #4 gdcli launch 命令（新功能，本次不做）
- #10 gdcli lsp 无子命令帮助（已修复）
- #12 gdextension arm64 Linux（低优先级）
- #15 clippy 警告清理（已无警告）

## 2. 设计决策

### 2.1 组 A：纯 Rust 侧修复（#3, #8, #9, #11, #14）

#### #3 HTTP header 注入防护
- `write_response()` 中检查 header name/value 是否包含 `\r\n`
- 包含则 panic（内部使用场景，fail-fast）

#### #8 HTTP 边界测试补充
新增测试用例：
- header value 为空
- Content-Length 带前导零
- 大写 CONTENT-LENGTH
- method/path 缺失
- 未知状态码

#### #9 project.godot 解析健壮性
改进 `enable_plugin_in_project_godot()`：
- 处理 `enabled=PackedStringArray()` 空数组（已有）
- 处理 `enabled=` 值带空格
- 处理多个 `enabled=` 行（取第一个）
- 处理 `enabled` 行不在 `[editor_plugins]` 段内

#### #11 PackedByteArray 构造优化
`lib.rs` 中两处：
- `poll_request()`：`body.push(b)` → `PackedByteArray::from(&req.body)`
- `send_response()`：`body_vec.push(body.get(i))` → `body.to_vec()` 或 slice 转换

#### #14 dead_code 警告清理
- `embedded_addon.rs`：移除 `addon_dir()` 和 `file_list()` 函数（未被调用）

### 2.2 组 B：gdcli status 扩展

**现状**：`gdcli status` 只检测 LSP 连通性。

**目标**：同时检测 exec（HTTP）和 LSP 连通性。

**输出格式（人类可读）**：
```
gdapi (HTTP):  ✅ connected (127.0.0.1:7890)
LSP:           ✅ connected (127.0.0.1:6005)
Project:       /path/to/project
```

**输出格式（JSON 模式）**：
```json
{
  "gdapi": { "connected": true, "host": "127.0.0.1", "port": 7890 },
  "lsp": { "connected": true, "host": "127.0.0.1", "port": 6005 },
  "project": "/path/to/project"
}
```

**实现**：
- 从 `.godot/gdapi.json` 读取 `http_port` 和 `lsp_port`
- HTTP 连通性：GET `http://127.0.0.1:{http_port}/ping`（或 HEAD 请求）
- LSP 连通性：现有 `GodotLspClient::connect()`
- 任一失败不 exit(1)，而是输出状态后正常退出

### 2.3 组 C：版本号统一管理（#13）

**现状**：版本号分散在三处：
- `Cargo.toml` → `workspace.package.version = "0.2.0"`
- `gdapi/addon/plugin.cfg` → `version="0.2.0"`
- `gdapi/addon/plugin.gd` → `"gdapi_version": "0.2.0"`

**方案**：Cargo.toml 为唯一来源，通过 `build.rs` 生成版本常量。

**实现**：

1. **cli/build.rs**：读取 `Cargo.toml` 的 `workspace.package.version`，生成 `version.rs`：
   ```rust
   // 自动生成
   pub const GDAPI_VERSION: &str = "0.2.0";
   ```

2. **cli/src/main.rs**：`include!` 生成的版本常量，在 install 时写入 plugin.cfg

3. **gdapi/addon/plugin.gd**：读取 plugin.cfg 的版本号，或从 GDExtension 侧获取

4. **plugin.cfg**：保留静态版本号，但由 install 命令自动更新

**工作流**：
- 发布时只需修改 `Cargo.toml` 的版本号
- `cargo build` 自动生成 `version.rs`
- `gdcli install` 时将版本号写入 plugin.cfg

### 2.4 组 D：认证机制（#7）

**方案**：gdapi 启动时自生成 token，写入元数据文件。

**实现**：

#### gdapi 侧（plugin.gd）
1. `_enter_tree` 时生成随机 token（32 字符 hex）
2. 写入 `.godot/gdapi.json` 的 `token` 字段
3. HTTP 请求处理时校验 `Authorization: Bearer <token>` header
4. 校验失败返回 401 Unauthorized

#### gdapi HTTP 服务器侧（server.rs）
1. `ServerCore` 新增 `expected_token: Option<String>` 字段
2. `start()` 时接收 token 参数，存储到 `expected_token`
3. `accept_loop` 中，解析请求后检查 `Authorization: Bearer <token>` header
4. token 不匹配则返回 401 响应，不传递到 GDScript 层
5. `expected_token` 为 `None` 时跳过认证（向后兼容）

#### gdapi GDExtension 侧（lib.rs）
1. `GdApiServer::start()` 新增 `token: GString` 参数
2. 传递给 `ServerCore::start()`

#### gdcli 侧
1. `gdapi_meta.rs`：`GdApiMeta` 新增 `token: Option<String>` 字段
2. `exec.rs`：HTTP 请求时添加 `Authorization: Bearer {token}` header
3. `commands/lsp.rs`：status 命令显示 token 状态

#### 安全考虑
- token 仅在 `.godot/gdapi.json` 中，文件权限保护
- 本地回环地址，风险可控
- token 为空时跳过认证（向后兼容）

### 2.5 组 E：LSP 端口自动重映射（#5）

**方案**：gdapi 从 EditorSettings 读取当前实例的 LSP 端口，写入元数据。

**实现**：

#### gdapi 侧（plugin.gd）
```gdscript
func _detect_lsp_port() -> int:
    var es := EditorInterface.get_editor_settings()
    if es and es.has_setting("network/language_server/remote_port"):
        return int(es.get_setting("network/language_server/remote_port"))
    return 6005  # 默认值
```

**写入元数据**：`_write_meta(port)` 时使用这个检测到的端口。

**多实例场景**：
- 实例 A：EditorSettings 端口 = 6005 → gdapi 读取到 6005
- 实例 B：EditorSettings 端口 = 6006 → gdapi 读取到 6006
- 各自写入各自的 `.godot/gdapi.json`

**gdcli 侧**：无需修改，已通过 `gdapi_meta::read()` 读取 `lsp_port`。

### 2.6 组 F：路由热重载（#6）

**方案**：利用 Godot 编辑器的 `EditorFileSystem.filesystem_changed` 信号。

**实现**：

#### plugin.gd 修改
```gdscript
func _enter_tree() -> void:
    # ... 现有代码 ...
    
    # 连接文件系统变化信号，实现路由热重载
    var fs = EditorInterface.get_resource_filesystem()
    fs.filesystem_changed.connect(_on_filesystem_changed)

func _on_filesystem_changed() -> void:
    if _router:
        _router.scan("res://addons/gdapi/routes")
        print("[gdapi] routes reloaded (%d routes)" % _router.count())
```

**触发条件**：
- 用户在编辑器中修改、添加、删除 `addons/gdapi/routes/` 下的 .gd 文件
- Godot 编辑器检测到文件变化，触发 `filesystem_changed` 信号
- gdapi 插件重新扫描路由目录，更新路由表

**注意事项**：
- `filesystem_changed` 信号在任何文件变化时都会触发，需要考虑是否需要过滤
- 可以添加防抖机制，避免频繁重载
- 重载时 `_routes.clear()` 然后重新 `scan()`

## 3. 实现计划

### 阶段 1：纯 Rust 侧修复（#3, #8, #9, #11, #14）
1. 修复 HTTP header 注入防护
2. 补充 HTTP 边界测试
3. 改进 project.godot 解析健壮性
4. 优化 PackedByteArray 构造
5. 清理 dead_code 警告

### 阶段 2：版本号统一管理（#13）
1. 创建 cli/build.rs
2. 修改 plugin.cfg 处理逻辑
3. 修改 plugin.gd 版本号读取

### 阶段 3：gdcli status 扩展
1. 修改 handle_status_command 函数
2. 添加 HTTP 连通性检测
3. 更新输出格式

### 阶段 4：认证机制（#7）
1. 修改 gdapi 侧：token 生成和校验
2. 修改 gdcli 侧：token 读取和传递
3. 更新 status 命令显示 token 状态

### 阶段 5：LSP 端口重映射（#5）
1. 修改 plugin.gd：检测 LSP 端口
2. 修改 _write_meta 函数

### 阶段 6：路由热重载（#6）
1. 修改 plugin.gd：连接文件系统信号
2. 实现 _on_filesystem_changed 回调

## 4. 测试计划

### 单元测试
- HTTP 边界测试补充
- project.godot 解析健壮性测试

### 集成测试
- gdcli status 双检测测试
- 认证机制测试（需要 mock）

### 手动测试
- 路由热重载测试（需要 Godot 编辑器）
- LSP 端口重映射测试（需要 Godot 编辑器）

## 5. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 认证机制破坏现有 API | 高 | token 为空时跳过认证（向后兼容） |
| 路由热重载频繁触发 | 中 | 添加防抖机制 |
| 版本号管理复杂化 | 低 | build.rs 自动生成，减少手动维护 |
