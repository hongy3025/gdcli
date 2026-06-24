//! LSP（Language Server Protocol）客户端模块。
//!
//! 本模块实现了与 Godot 内置 LSP 服务器的通信功能，包括：
//! - `client`: LSP 客户端，封装请求/响应逻辑
//! - `transport`: TCP 传输层，处理连接和消息收发
//! - `types`: LSP 协议数据类型定义
//! - `symbol_path`: 符号路径解析（如 `Player.health`）
//!
//! 该模块是 gdcli 与 Godot 编辑器 LSP 功能交互的核心。

pub mod client;
pub mod symbol_path;
pub mod transport;
pub mod types;
