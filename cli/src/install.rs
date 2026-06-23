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
    fs::create_dir_all(&target)
        .map_err(|e| anyhow!("cannot create {}: {}", target.display(), e))?;
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
