//! 命令处理模块。
//!
//! 本模块包含 gdcli 各个子命令的具体实现逻辑。
//! 目前包含：
//! - `lsp`: LSP 相关命令的处理器（rename、references、definition 等）
//!
//! 每个子模块负责将用户命令转换为 LSP 请求，并格式化输出结果。

pub mod lsp;
