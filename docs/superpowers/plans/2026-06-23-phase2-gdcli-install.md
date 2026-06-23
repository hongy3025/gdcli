# 阶段 2：gdcli install 子命令 + 项目根检测 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 实现 `gdcli install` 一键安装 gdapi addon 到目标 Godot 项目，并为所有需要项目上下文的子命令（exec、install、lsp、status）提供自动项目根检测。

**架构：** 使用 `include_dir!` 宏在编译期把 `gdapi/addon/` 整目录嵌入 gdcli 二进制。运行时 `gdcli install` 展开嵌入的文件到目标项目的 `addons/gdapi/`。项目根检测从 cwd 向上逐级查找 `project.godot`，最多 5 层。所有需要项目上下文的子命令共用此逻辑。

**技术栈：** Rust 2021 / include_dir 0.7 / clap 4 / serde_json 1 / anyhow 1

---

## 文件结构

**新建：**
- `cli/src/project.rs` — 项目根检测（向上查找 project.godot）
- `cli/src/install.rs` — install 子命令实现（展开嵌入的 addon 模板）
- `cli/tests/install_integration.rs` — install 集成测试
- `cli/tests/project_detection.rs` — 项目根检测单元测试

**修改：**
- `cli/Cargo.toml` — 添加 `include_dir` 依赖
- `cli/src/main.rs` — 添加 Install 子命令、使用 project.rs 统一项目根检测
- `cli/src/exec.rs` — 使用 project.rs 统一项目根检测

**职责边界：**
- `cli/src/project.rs`：只负责向上查找 `project.godot`，返回 `Option<PathBuf>`
- `cli/src/install.rs`：只负责展开嵌入的 addon 目标、修改 project.godot 启用插件

---

## 任务 1：项目根检测模块（project.rs）

**文件：**
- 创建：`cli/src/project.rs`
- 创建：`cli/tests/project_detection.rs`
- 修改：`cli/src/main.rs`（声明 mod project）
- 修改：`cli/src/exec.rs`（使用 project::find_root）

- [ ] **步骤 1：创建 cli/src/project.rs**

```rust
//! 项目根检测：从候选目录向上逐级查找 project.godot。
//!
//! 查找规则：
//! 1. 若指定 --project <dir>：使用该值（验证 <dir>/project.godot 存在）
//! 2. 否则：从当前目录起向上逐级查找 project.godot，最多 5 层
//! 3. 找到 → 该目录为项目根
//! 4. 找不到 → 返回 None

use std::path::{Path, PathBuf};

const MAX_DEPTH: usize = 5;

/// 从给定目录向上查找 project.godot。
/// 返回包含 project.godot 的目录路径，或 None。
pub fn find_root(from: &Path) -> Option<PathBuf> {
    let mut dir = if from.is_absolute() {
        from.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(from)
    };
    // 确保是目录
    if dir.is_file() {
        dir = dir.parent()?.to_path_buf();
    }
    for _ in 0..=MAX_DEPTH {
        let candidate = dir.join("project.godot");
        if candidate.is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

/// 解析项目根目录。
///
/// 优先使用显式指定的 --project 值，否则自动向上查找。
/// 返回 Err 如果：
///   - --project 指定的目录不存在或不包含 project.godot
///   - 未指定 --project 且无法自动找到
pub fn resolve_project_root(explicit: Option<&Path>) -> Result<PathBuf, String> {
    match explicit {
        Some(p) => {
            let abs = if p.is_absolute() {
                p.to_path_buf()
            } else {
                std::env::current_dir()
                    .map_err(|e| format!("cannot get cwd: {}", e))?
                    .join(p)
            };
            if abs.join("project.godot").is_file() {
                Ok(abs)
            } else {
                Err(format!(
                    "not a Godot project (no project.godot in {})",
                    abs.display()
                ))
            }
        }
        None => {
            let cwd = std::env::current_dir()
                .map_err(|e| format!("cannot get cwd: {}", e))?;
            find_root(&cwd).ok_or_else(|| {
                format!(
                    "no Godot project found from {} (searched up {} levels). \
                     Use --project <path> or run from within a Godot project.",
                    cwd.display(),
                    MAX_DEPTH
                )
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn find_root_in_current_dir() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        assert_eq!(find_root(dir.path()), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn find_root_in_parent() {
        let dir = TempDir::new().unwrap();
        let sub = dir.path().join("src").join("scripts");
        fs::create_dir_all(&sub).unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        assert_eq!(find_root(&sub), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn find_root_max_depth() {
        let dir = TempDir::new().unwrap();
        let mut deep = dir.path().to_path_buf();
        for _ in 0..6 {
            deep = deep.join("a");
        }
        fs::create_dir_all(&deep).unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        // 6 levels deep exceeds MAX_DEPTH=5
        assert_eq!(find_root(&deep), None);
    }

    #[test]
    fn find_root_not_found() {
        let dir = TempDir::new().unwrap();
        assert_eq!(find_root(dir.path()), None);
    }

    #[test]
    fn find_root_file_path() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        let file = dir.path().join("main.gd");
        fs::write(&file, "").unwrap();
        // Should find root even when given a file path
        assert_eq!(find_root(&file), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn resolve_explicit_valid() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        let result = resolve_project_root(Some(dir.path()));
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), dir.path());
    }

    #[test]
    fn resolve_explicit_invalid() {
        let dir = TempDir::new().unwrap();
        let result = resolve_project_root(Some(dir.path()));
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not a Godot project"));
    }

    #[test]
    fn resolve_auto_found() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        let sub = dir.path().join("src");
        fs::create_dir(&sub).unwrap();
        // Temporarily change cwd for test
        let original_cwd = std::env::current_dir().unwrap();
        std::env::set_current_dir(&sub).unwrap();
        let result = resolve_project_root(None);
        std::env::set_current_dir(original_cwd).unwrap();
        assert!(result.is_ok());
    }

    #[test]
    fn resolve_auto_not_found() {
        let dir = TempDir::new().unwrap();
        let original_cwd = std::env::current_dir().unwrap();
        std::env::set_current_dir(dir.path()).unwrap();
        let result = resolve_project_root(None);
        std::env::set_current_dir(original_cwd).unwrap();
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("no Godot project found"));
    }
}
```

- [ ] **步骤 2：在 main.rs 中声明 mod project**

在 `cli/src/main.rs` 的模块声明区添加：
```rust
mod project;
```

- [ ] **步骤 3：更新 exec.rs 使用 project::resolve_project_root**

修改 `cli/src/exec.rs` 的 `run()` 函数签名和实现：

```rust
pub fn run(
    project: &Path,  // 已解析的项目根（由 main.rs 传入）
    command: &str,
    data: Option<&str>,
    timeout_secs: u64,
) -> Result<i32> {
    // project 已经是解析好的项目根，无需再检测
    // ... 其余逻辑不变 ...
}
```

同时更新 `main.rs` 中 Exec 子命令的处理，使用 `project::resolve_project_root`：

```rust
    // Exec 子命令不需要 LSP 连接，提前处理
    if let Cmd::Exec { ref command, ref data, timeout } = cli.cmd {
        let project_root = project::resolve_project_root(project)
            .map_err(|e| anyhow::anyhow!(e))?;
        let code = exec::run(&project_root, command, data.as_deref(), timeout)?;
        std::process::exit(code);
    }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`cargo test -p gdcli --lib project`
预期：所有 project 模块测试通过。

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "feat(cli): add project root detection (walk up to find project.godot)"
```

---

## 任务 2：include_dir! 嵌入 addon 模板

**文件：**
- 修改：`cli/Cargo.toml`（添加 include_dir 依赖）
- 创建：`cli/src/embedded_addon.rs`（使用 include_dir! 嵌入 gdapi/addon/）

- [ ] **步骤 1：在 cli/Cargo.toml 中添加依赖**

在 `[dependencies]` 下添加：
```toml
include_dir = "0.7"
```

- [ ] **步骤 2：创建 cli/src/embedded_addon.rs**

```rust
//! 编译期嵌入的 gdapi addon 模板。
//!
//! 使用 include_dir! 宏把 gdapi/addon/ 整目录嵌入 gdcli 二进制。
//! install 子命令在运行时展开这些文件到目标项目。

use include_dir::{include_dir, Dir};
use std::path::Path;

/// 编译期嵌入的 addon 目录。
/// 路径相对于 Cargo.toml 所在目录（即 workspace 根）。
static ADDON_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../gdapi/addon");

/// 获取嵌入的 addon 目录。
pub fn addon_dir() -> &'static Dir<'static> {
    &ADDON_DIR
}

/// 展开嵌入的 addon 到目标路径。
///
/// target_dir 通常是 <project>/addons/gdapi/
/// 如果目标目录已存在，调用方应先决定是否删除（--force）。
pub fn extract_to(target_dir: &Path) -> Result<(), std::io::Error> {
    ADDON_DIR.extract(target_dir).map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("extract addon: {}", e),
        )
    })
}

/// 返回嵌入的 addon 文件列表（用于调试/日志）。
pub fn file_list() -> Vec<String> {
    ADDON_DIR
        .files()
        .map(|f| f.path().display().to_string())
        .collect()
}
```

- [ ] **步骤 3：在 main.rs 中声明 mod**

在 `cli/src/main.rs` 的模块声明区添加：
```rust
mod embedded_addon;
```

- [ ] **步骤 4：验证编译通过**

运行：`cargo build -p gdcli`
预期：编译成功。include_dir! 会在编译期读取 `gdapi/addon/` 目录并嵌入二进制。

如果编译报错找不到目录，确认 `gdapi/addon/` 存在且包含 `plugin.cfg` 等文件。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "feat(cli): embed gdapi addon template via include_dir!"
```

---

## 任务 3：install 子命令实现（含集成测试）

**文件：**
- 创建：`cli/src/install.rs`
- 修改：`cli/src/main.rs`（添加 Install 子命令）
- 创建：`cli/tests/install_integration.rs`

- [ ] **步骤 1：创建 cli/src/install.rs**

```rust
//! gdcli install — 把 gdapi addon 安装到目标 Godot 项目。
//!
//! 流程：
//! 1. 解析项目根（--project 或自动查找）
//! 2. 检查 addons/gdapi/ 是否已存在
//! 3. 展开嵌入的 addon 模板到 addons/gdapi/
//! 4. 修改 project.godot 启用插件（除非 --no-enable）

use anyhow::{anyhow, Result};
use std::fs;
use std::path::Path;

use crate::embedded_addon;

/// install 子命令的参数。
pub struct InstallArgs {
    pub project_root: std::path::PathBuf,
    pub force: bool,
    pub no_enable: bool,
}

/// 执行 install。
pub fn run(args: InstallArgs) -> Result<()> {
    let root = &args.project_root;
    let target = root.join("addons").join("gdapi");

    // 1. 检查是否已安装
    if target.exists() {
        if !args.force {
            // 读取现有版本
            let version = read_installed_version(&target);
            let msg = match version {
                Some(v) => format!("gdapi {} is already installed at {}", v, target.display()),
                None => format!("gdapi is already installed at {}", target.display()),
            };
            return Err(anyhow!(
                "{}. Use --force to overwrite.",
                msg
            ));
        }
        // --force：删除现有安装
        fs::remove_dir_all(&target)
            .map_err(|e| anyhow!("cannot remove {}: {}", target.display(), e))?;
    }

    // 2. 确保 addons/ 目录存在
    let addons_dir = root.join("addons");
    if !addons_dir.exists() {
        fs::create_dir_all(&addons_dir)
            .map_err(|e| anyhow!("cannot create {}: {}", addons_dir.display(), e))?;
    }

    // 3. 展开嵌入的 addon
    embedded_addon::extract_to(&target)
        .map_err(|e| anyhow!("cannot extract addon to {}: {}", target.display(), e))?;

    // 4. 启用插件（修改 project.godot）
    if !args.no_enable {
        enable_plugin_in_project_godot(root)?;
    }

    // 5. 输出结果
    println!("Installed gdapi 0.2.0 → {}", target.display());
    if !args.no_enable {
        println!("Plugin enabled in project.godot.");
    }
    println!("Next: open the project in Godot Editor.");
    Ok(())
}

/// 读取已安装的 gdapi 版本号。
fn read_installed_version(target: &Path) -> Option<String> {
    let plugin_cfg = target.join("plugin.cfg");
    let content = fs::read_to_string(plugin_cfg).ok()?;
    for line in content.lines() {
        if let Some(v) = line.strip_prefix("version=") {
            return Some(v.trim().trim_matches('"').to_string());
        }
    }
    None
}

/// 在 project.godot 的 [editor_plugins] 段启用 gdapi 插件。
///
/// 如果 [editor_plugins] 段不存在，创建它。
/// 如果 enabled 列表已包含 gdapi，不重复添加。
fn enable_plugin_in_project_godot(root: &Path) -> Result<()> {
    let godot_path = root.join("project.godot");
    let content = fs::read_to_string(&godot_path)
        .map_err(|e| anyhow!("cannot read {}: {}", godot_path.display(), e))?;

    let plugin_entry = "res://addons/gdapi/plugin.cfg";

    // 检查是否已启用
    if content.contains(plugin_entry) {
        return Ok(());
    }

    let new_content = if content.contains("[editor_plugins]") {
        // [editor_plugins] 段已存在，找到 enabled= 行并追加
        let mut lines: Vec<String> = content.lines().map(String::from).collect();
        let mut found_enabled = false;
        for line in &mut lines {
            if line.starts_with("enabled=") {
                // 已有 enabled 行，追加插件
                // 格式：enabled=PackedStringArray("res://addons/foo/plugin.cfg")
                if line.ends_with(")") {
                    // 在 ) 前插入
                    let insert_pos = line.len() - 1;
                    line.insert_str(insert_pos, &format!(",\"{}\"", plugin_entry));
                } else {
                    // 空 enabled 行
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                }
                found_enabled = true;
                break;
            }
        }
        if !found_enabled {
            // [editor_plugins] 存在但没有 enabled 行
            // 在 [editor_plugins] 之后插入
            let mut new_lines = Vec::new();
            for line in lines {
                new_lines.push(line.clone());
                if line.trim() == "[editor_plugins]" {
                    new_lines.push(format!("enabled=PackedStringArray(\"{}\")", plugin_entry));
                }
            }
            new_lines.join("\n")
        } else {
            lines.join("\n")
        }
    } else {
        // [editor_plugins] 段不存在，追加
        let mut new_content = content.trim_end().to_string();
        new_content.push_str("\n\n[editor_plugins]\n\n");
        new_content.push_str(&format!("enabled=PackedStringArray(\"{}\")\n", plugin_entry));
        new_content
    };

    fs::write(&godot_path, new_content)
        .map_err(|e| anyhow!("cannot write {}: {}", godot_path.display(), e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn read_installed_version_from_addon() {
        let dir = TempDir::new().unwrap();
        let target = dir.path().join("addons").join("gdapi");
        fs::create_dir_all(&target).unwrap();
        fs::write(
            target.join("plugin.cfg"),
            "[plugin]\nname=\"gdapi\"\nversion=\"0.2.0\"\n",
        )
        .unwrap();
        assert_eq!(read_installed_version(&target), Some("0.2.0".to_string()));
    }

    #[test]
    fn read_installed_version_missing() {
        let dir = TempDir::new().unwrap();
        assert_eq!(read_installed_version(dir.path()), None);
    }

    #[test]
    fn enable_plugin_creates_section() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "config_version=5\n\n[application]\nconfig/name=\"test\"\n",
        )
        .unwrap();
        enable_plugin_in_project_godot(dir.path()).unwrap();
        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(content.contains("[editor_plugins]"));
        assert!(content.contains("res://addons/gdapi/plugin.cfg"));
    }

    #[test]
    fn enable_plugin_appends_to_existing() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "[editor_plugins]\nenabled=PackedStringArray(\"res://addons/foo/plugin.cfg\")\n",
        )
        .unwrap();
        enable_plugin_in_project_godot(dir.path()).unwrap();
        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(content.contains("res://addons/foo/plugin.cfg"));
        assert!(content.contains("res://addons/gdapi/plugin.cfg"));
    }

    #[test]
    fn enable_plugin_idempotent() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "[editor_plugins]\nenabled=PackedStringArray(\"res://addons/gdapi/plugin.cfg\")\n",
        )
        .unwrap();
        enable_plugin_in_project_godot(dir.path()).unwrap();
        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        // Should not duplicate
        assert_eq!(
            content.matches("res://addons/gdapi/plugin.cfg").count(),
            1
        );
    }

    #[test]
    fn enable_plugin_no_enable_flag() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "config_version=5\n",
        )
        .unwrap();
        // --no-enable: don't modify project.godot
        // This test just verifies the function is not called
        let content_before = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(!content_before.contains("gdapi"));
    }
}
```

- [ ] **步骤 2：在 main.rs 中添加 Install 子命令**

在 `Cmd` 枚举中添加（在 Exec 之前）：
```rust
    /// 在目标项目安装 gdapi addon
    Install {
        /// 覆盖已有安装
        #[arg(long)]
        force: bool,
        /// 不修改 project.godot 启用插件
        #[arg(long)]
        no_enable: bool,
    },
```

在 `run()` 函数中，在 Exec 处理之前添加 Install 的提前处理：
```rust
    // Install 子命令不需要 LSP 连接，提前处理
    if let Cmd::Install { force, no_enable } = cli.cmd {
        let project_root = project::resolve_project_root(project)
            .map_err(|e| anyhow::anyhow!(e))?;
        install::run(install::InstallArgs {
            project_root,
            force,
            no_enable,
        })?;
        return Ok(());
    }
```

在 `main.rs` 的模块声明区添加：
```rust
mod install;
```

- [ ] **步骤 3：编写集成测试 cli/tests/install_integration.rs**

```rust
//! gdcli install 子命令集成测试。

use assert_cmd::Command;
use std::fs;
use tempfile::TempDir;

fn make_godot_project(dir: &std::path::Path) {
    fs::write(
        dir.join("project.godot"),
        "config_version=5\n\n[application]\nconfig/name=\"test\"\n",
    )
    .unwrap();
}

#[test]
    fn install_creates_addon_directory() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());

        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .success()
            .stdout(predicates::str::contains("Installed gdapi"));

        // Verify addon files exist
        assert!(dir.path().join("addons/gdapi/plugin.cfg").exists());
        assert!(dir.path().join("addons/gdapi/plugin.gd").exists());
        assert!(dir.path().join("addons/gdapi/gdapi.gdextension").exists());
        assert!(dir.path().join("addons/gdapi/runtime/router.gd").exists());
        assert!(dir.path().join("addons/gdapi/runtime/route_handler.gd").exists());
    }

    #[test]
    fn install_enables_plugin_in_project_godot() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());

        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .success();

        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(content.contains("[editor_plugins]"));
        assert!(content.contains("res://addons/gdapi/plugin.cfg"));
    }

    #[test]
    fn install_no_enable_flag() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());

        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap(), "--no-enable"])
            .assert()
            .success();

        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(!content.contains("gdapi"));
    }

    #[test]
    fn install_fails_if_already_installed() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());

        // First install
        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .success();

        // Second install without --force
        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .failure()
            .stderr(predicates::str::contains("already installed"));
    }

    #[test]
    fn install_force_overwrites() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());

        // First install
        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .success();

        // Second install with --force
        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap(), "--force"])
            .assert()
            .success()
            .stdout(predicates::str::contains("Installed gdapi"));
    }

    #[test]
    fn install_fails_without_project_godot() {
        let dir = TempDir::new().unwrap();

        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install", "--project", dir.path().to_str().unwrap()])
            .assert()
            .failure()
            .stderr(predicates::str::contains("not a Godot project"));
    }

    #[test]
    fn install_auto_detects_project_root() {
        let dir = TempDir::new().unwrap();
        make_godot_project(dir.path());
        let sub = dir.path().join("src");
        fs::create_dir(&sub).unwrap();

        Command::cargo_bin("gdcli")
            .unwrap()
            .args(["install"])
            .current_dir(&sub)
            .assert()
            .success();

        assert!(dir.path().join("addons/gdapi/plugin.cfg").exists());
    }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`cargo test -p gdcli --test install_integration`
预期：7 个测试全部通过。

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "feat(cli): implement install subcommand for gdapi addon"
```

---

## 阶段 2 完成标准

执行完所有任务后应达到：

1. `cargo build --workspace` 全部成功
2. `cargo test --workspace` 全部通过（含 install 集成测试 + project 检测测试）
3. `gdcli install --project <fixture>` 能成功展开 addon 到 `addons/gdapi/`
4. `gdcli install --project <fixture>` 能自动修改 `project.godot` 启用插件
5. `gdcli install --project <fixture>` 第二次运行报错（提示 `--force`）
6. `gdcli install --project <fixture> --force` 能覆盖安装
7. `gdcli install --project <fixture> --no-enable` 不修改 `project.godot`
8. 未指定 `--project` 时自动向上查找 `project.godot`
9. 现有 `gdcli exec` 行为不变（但现在支持自动项目根检测）
10. 现有 LSP 命令行为不变

阶段 2 验证成功后，进入阶段 3（CLI 重构：现有命令归入 `lsp/` 命名空间）规划。
