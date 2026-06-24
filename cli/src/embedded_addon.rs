//! 编译期嵌入的 gdapi addon 模板。
//!
//! 使用 include_dir! 宏把 gdapi/addon/ 整目录嵌入 gdcli 二进制。
//! install 子命令在运行时展开这些文件到目标项目。

use include_dir::{include_dir, Dir};
use std::path::Path;

/// 编译期嵌入的 addon 目录。
/// 路径相对于本 crate 的 Cargo.toml（cli/），`../` 导航到 workspace 根。
static ADDON_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../gdapi/addon");

/// 获取嵌入的 addon 目录。
#[allow(dead_code)]
pub fn addon_dir() -> &'static Dir<'static> {
    &ADDON_DIR
}

/// 展开嵌入的 addon 到目标路径。
///
/// target_dir 通常是 <project>/addons/gdapi/
/// 如果目标目录已存在，调用方应先决定是否删除（--force）。
pub fn extract_to(target_dir: &Path) -> Result<(), std::io::Error> {
    ADDON_DIR.extract(target_dir)
}

/// 返回嵌入的 addon 文件列表（用于调试/日志）。
#[allow(dead_code)]
pub fn file_list() -> Vec<String> {
    ADDON_DIR
        .files()
        .map(|f| f.path().display().to_string())
        .collect()
}
