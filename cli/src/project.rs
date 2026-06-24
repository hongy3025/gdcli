//! Godot 项目根目录查找与解析。
//!
//! 本模块提供项目根目录的自动发现功能，通过向上查找 `project.godot` 文件
//! 来定位 Godot 项目的根目录。
//!
//! 核心功能：
//! - `find_root`: 从指定路径向上查找项目根目录
//! - `resolve_project_root`: 解析并验证项目根目录（支持显式指定或自动查找）
//!
//! 查找策略：
//! - 从给定路径开始，逐级向上查找 `project.godot` 文件
//! - 最多向上查找 MAX_DEPTH 层（防止在文件系统根目录无限循环）
//! - 如果给定路径是文件，先取其父目录再开始查找

use std::path::{Path, PathBuf};

/// 向上查找项目根目录的最大层数。
///
/// 防止在文件系统根目录附近无限循环，同时允许合理的目录嵌套深度。
const MAX_DEPTH: usize = 5;

/// 从指定路径开始向上查找 Godot 项目根目录。
///
/// 通过查找 `project.godot` 文件来确定项目根目录位置。
/// 如果给定路径是文件，会先取其父目录再开始查找。
///
/// # Arguments
/// * `from` - 起始查找路径（可以是文件或目录）
///
/// # Returns
/// - `Some(PathBuf)`: 找到的项目根目录路径
/// - `None`: 在 MAX_DEPTH 层内未找到 project.godot 文件
pub fn find_root(from: &Path) -> Option<PathBuf> {
    let mut dir = if from.is_absolute() {
        from.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(from)
    };
    // 如果给定路径是文件，先取其父目录
    if dir.is_file() {
        dir = dir.parent()?.to_path_buf();
    }
    // 逐级向上查找 project.godot 文件
    for _ in 0..=MAX_DEPTH {
        let candidate = dir.join("project.godot");
        if candidate.is_file() {
            return Some(dir);
        }
        // pop() 返回 false 表示已到文件系统根目录
        if !dir.pop() {
            break;
        }
    }
    None
}

/// 解析并验证 Godot 项目根目录。
///
/// 支持两种模式：
/// 1. 显式指定：验证给定路径是否包含 project.godot 文件
/// 2. 自动查找：从当前工作目录向上查找
///
/// # Arguments
/// * `explicit` - 可选的显式项目路径
///
/// # Returns
/// 验证通过的项目根目录绝对路径
///
/// # Errors
/// - 显式路径不包含 project.godot 文件
/// - 自动查找在 MAX_DEPTH 层内未找到项目
/// - 无法获取当前工作目录
pub fn resolve_project_root(explicit: Option<&Path>) -> Result<PathBuf, String> {
    match explicit {
        Some(p) => {
            // 显式指定路径：转为绝对路径并验证
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
            // 自动查找模式：从当前工作目录开始
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
