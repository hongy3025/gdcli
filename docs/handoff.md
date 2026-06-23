# gdcli 开发交接文档

- **日期**：2026-06-24
- **版本**：v0.2.0（已发布）
- **仓库**：https://github.com/hongy3025/gdcli

## 当前状态

```
测试：113/113 全部通过
分支：main（已推送）
Tag：v0.2.0
```

### 已完成的功能

| 功能 | 状态 |
|---|---|
| `gdcli install` — 一键安装 gdapi addon | ✅ |
| `gdcli exec` — HTTP 调用 Godot 编辑器 | ✅ |
| `gdcli lsp` — LSP 命令（自动端口发现） | ✅ |
| 14 个 gdapi 路由（godot-mcp 迁移） | ✅ |
| 项目根自动检测 | ✅ |
| debug_output 滚动缓冲区 | ✅ |
| main.rs 拆分到 commands/lsp.rs | ✅ |

---

## 遗留 TODO 项

### 高优先级

| # | 内容 | 来源 | 说明 |
|---|---|---|---|
| 1 | **实际 Godot 端到端验证** | 阶段 1 | 在真实 Godot 4.3+ 项目中跑 `gdcli install` + `gdcli exec ping` + `gdcli exec routes`。需要本地安装 Godot。 |
| 2 | **CI/CD 流水线** | 阶段 5 | GitHub Actions：自动测试 + 全平台构建（Windows/macOS/Linux）+ release 发布。参考设计规格 §10.2。 |
| 3 | **HTTP header 注入防护** | 阶段 1 代码审查 | `gdapi/rust/src/http.rs` 的 `write_response` 未检查 header value 中的 `\r\n`，存在 header 注入风险。内部使用场景风险低，但应修复。 |

### 中优先级

| # | 内容 | 来源 | 说明 |
|---|---|---|---|
| 4 | **gdcli launch 命令** | 设计规格 §7.3 | 新增 `gdcli launch <project>` 启动 Godot 编辑器。godot-mcp 的 `launch_editor` 未迁移，因为 gdapi 在编辑器未启动时不可达。但作为 gdcli 顶层命令有意义。 |
| 5 | **LSP 端口自动重映射** | 设计规格 §1 | 多 Godot 实例并存时，LSP 端口冲突。当前靠 `--project` 区分。未来可让 gdapi 自动探测可用 LSP 端口并写入 `.godot/gdapi.json`。 |
| 6 | **gdapi 路由热重载** | 设计规格 §5.7 | 修改路由脚本后需要重启编辑器才能生效。可实现文件监听 + 自动重新扫描。 |
| 7 | **gdapi 认证机制** | 设计规格 §4.4 | HTTP server 绑定 127.0.0.1 但无认证。可添加简单的 token 认证（gdcli install 时生成随机 token 写入 `.godot/gdapi.json`）。 |
| 8 | **HTTP 边界测试补充** | 阶段 1 代码审查 | 缺少：header value 为空、Content-Length 带前导零、大写 CONTENT-LENGTH、method/path 缺失、未知状态码等测试场景。 |
| 9 | **project.godot 解析健壮性** | 阶段 2 代码审查 | `install.rs` 的 `enable_plugin_in_project_godot` 对边界格式容错不足（如空数组、带空格的值、多个 enabled 行）。 |
| 10 | **gdcli lsp 无子命令帮助** | 阶段 3 代码审查 | `gdcli lsp` 不带子命令时应显示帮助信息，当前会报错。 |

### 低优先级

| # | 内容 | 来源 | 说明 |
|---|---|---|---|
| 11 | **PackedByteArray 构造优化** | 阶段 1 代码审查 | `lib.rs` 中逐字节 push/get，可用 `PackedByteArray::from(&slice)` 替代。 |
| 12 | **gdextension 补充 arm64 Linux** | 阶段 1 代码审查 | `gdapi.gdextension` 缺少 `linux.debug.arm64` 条目。 |
| 13 | **版本号统一管理** | 阶段 2 | Cargo.toml、plugin.cfg、plugin.gd 中的版本号分散，可提取为单一来源。 |
| 14 | **dead_code 警告清理** | 全局 | `embedded_addon.rs` 中 `addon_dir()` 和 `file_list()` 未被调用，有 dead_code 警告。 |
| 15 | **clippy 警告清理** | 全局 | `lsp/client.rs`、`lsp/transport.rs` 中有 7 个 clippy 警告（冗余闭包、手动 find 等）。 |

---

## 架构概览

```
gdcli/                          # workspace 根
  cli/                          # gdcli 可执行
    src/
      main.rs                   # CLI 入口 + 命令分发（415 行）
      commands/lsp.rs           # LSP 命令处理器（~700 行）
      exec.rs                   # exec 子命令
      install.rs                # install 子命令
      project.rs                # 项目根检测
      embedded_addon.rs         # include_dir! 嵌入
      gdapi_meta.rs             # .godot/gdapi.json 读取
      lsp/                      # LSP 客户端核心
    tests/                      # 集成测试
  gdapi/
    rust/                       # GDExtension Rust 源码
      src/
        lib.rs                  # GdApiServer GodotClass
        server.rs               # tokio HTTP server
        http.rs                 # HTTP 解析器
        queue.rs                # 跨线程队列
    addon/                      # Godot addon 模板
      plugin.gd                 # EditorPlugin 入口
      runtime/router.gd         # 路由扫描与分发
      routes/editor/            # 编辑器路由
      routes/shared/            # 共享路由
```

## 测试覆盖

| 测试组 | 数量 |
|---|---|
| http 单元测试 | 14 |
| server 集成测试 | 4 |
| cli 单元测试 | 58 |
| addon_deploy 集成测试 | 7 |
| exec_integration | 6 |
| lsp_port_discovery | 4 |
| lsp_subcommand | 15 |
| mock_lsp | 5 |
| **总计** | **113** |

## 路由清单

| 路径 | 上下文 | 状态 |
|---|---|---|
| `/ping` | 内置 | ✅ |
| `/routes` | 内置 | ✅ |
| `/godot/version` | shared | ✅ |
| `/project/info` | shared | ✅ |
| `/uid/get` | shared | ✅ |
| `/project/run` | editor | ✅ |
| `/project/stop` | editor | ✅ |
| `/project/debug_output` | editor | ✅ 滚动缓冲区 |
| `/scene/create` | editor | ✅ |
| `/scene/add_node` | editor | ✅ |
| `/scene/load_sprite` | editor | ✅ |
| `/scene/save` | editor | ✅ |
| `/scene/export_mesh_library` | editor | ✅ |
| `/uid/update_all` | editor | ✅ |

## 设计文档

- 设计规格：`docs/superpowers/specs/2026-06-23-gdcli-godot-editor-tool-design.md`
- 需求文档：`docs/req/gdcli-扩展为通用godot编辑器操作工具.md`
- 实现计划：`docs/superpowers/plans/` 目录下 6 个计划文件
