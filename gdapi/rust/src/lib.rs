//! gdapi — Godot GDExtension HTTP 服务器库。
//!
//! 本库实现了 gdapi 的核心功能：在 Godot 游戏运行时启动一个轻量级 HTTP 服务器，
//! 允许外部工具（如 gdcli）通过 HTTP 请求与游戏交互。
//!
//! 模块结构：
//! - `queue`: 请求队列，线程安全地传递 HTTP 请求
//! - `http`: HTTP 协议解析器
//! - `server`: HTTP 服务器核心实现
//!
//! GDExtension 集成：
//! 通过 `#[gdextension]` 宏将 Rust 代码暴露为 Godot 可调用的类 `GdApiServer`。
//! GDScript 可以直接调用 `GdApiServer.create()`、`start()`、`poll_request()` 等方法。

pub mod queue;
pub mod http;
pub mod server;

use godot::prelude::*;
use server::ServerCore;

/// GDExtension 入口标记结构体。
///
/// 通过 `#[gdextension]` 宏告诉 Godot 这是一个 GDExtension 库。
struct GdApiExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GdApiExtension {}

/// GDScript 可调用的 HTTP 服务器类。
///
/// 封装了 `ServerCore`，提供 GDScript 友好的接口。
/// 使用 `RefCounted` 作为基类，支持 Godot 的引用计数内存管理。
///
/// # GDScript 使用示例
/// ```gdscript
/// var server = GdApiServer.create()
/// server.start(8080)
/// # 在 _process 中轮询请求
/// var req = server.poll_request()
/// if req != null:
///     server.send_response(req.id, 200, {}, "OK".to_utf8_buffer())
/// ```
#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    /// HTTP 服务器核心实例
    core: ServerCore,
}

#[godot_api]
impl GdApiServer {
    /// 创建一个新的 GdApiServer 实例。
    ///
    /// # Returns
    /// 包装为 Godot 智能指针的服务器实例
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self { core: ServerCore::new() })
    }

    /// 启动 HTTP 服务器。
    ///
    /// # Arguments
    /// * `port_hint` - 期望的端口号。如果被占用，会尝试其他端口。
    ///
    /// # Returns
    /// 实际监听的端口号，失败返回 -1
    #[func]
    fn start(&mut self, port_hint: u16) -> i32 {
        match self.core.start(port_hint) {
            Ok(p) => p as i32,
            Err(e) => {
                godot_error!("[gdapi] start failed: {}", e);
                -1
            }
        }
    }

    /// 停止 HTTP 服务器。
    #[func]
    fn stop(&mut self) {
        self.core.stop();
    }

    /// 检查服务器是否正在运行。
    ///
    /// # Returns
    /// 服务器运行状态
    #[func]
    fn is_running(&self) -> bool {
        self.core.is_running()
    }

    /// 获取服务器监听的端口号。
    ///
    /// # Returns
    /// 端口号（仅在服务器运行时有效）
    #[func]
    fn port(&self) -> i32 {
        self.core.port()
    }

    /// 轮询并获取下一个待处理的 HTTP 请求。
    ///
    /// 在 GDScript 的 `_process()` 中调用此方法检查新请求。
    ///
    /// # Returns
    /// 请求字典，包含以下字段：
    /// - `id`: 请求 ID（用于发送响应）
    /// - `method`: HTTP 方法（GET、POST 等）
    /// - `path`: 请求路径
    /// - `headers`: 请求头字典
    /// - `body`: 请求体（PackedByteArray）
    ///
    /// 如果没有待处理请求，返回 `null`。
    #[func]
    fn poll_request(&mut self) -> Variant {
        match self.core.poll_for_godot() {
            None => Variant::nil(),
            Some(req) => {
                let mut dict = Dictionary::<GString, Variant>::new();
                dict.set(&GString::from("id"), &Variant::from(req.id as i64));
                dict.set(&GString::from("method"), &Variant::from(GString::from(req.method.as_str())));
                dict.set(&GString::from("path"), &Variant::from(GString::from(req.path.as_str())));
                let mut hdrs = Dictionary::<GString, Variant>::new();
                for (k, v) in req.headers {
                    hdrs.set(&GString::from(k.as_str()), &Variant::from(GString::from(v.as_str())));
                }
                dict.set(&GString::from("headers"), &hdrs.to_variant());
                // 优化：使用 from slice 替代逐字节 push
                let body = PackedByteArray::from(req.body.as_slice());
                dict.set(&GString::from("body"), &body.to_variant());
                dict.to_variant()
            }
        }
    }

    /// 发送 HTTP 响应。
    ///
    /// # Arguments
    /// * `id` - 请求 ID（从 `poll_request` 获取）
    /// * `status` - HTTP 状态码（如 200、404、500）
    /// * `headers` - 响应头字典
    /// * `body` - 响应体（PackedByteArray）
    #[func]
    fn send_response(
        &mut self,
        id: i64,
        status: i64,
        headers: Dictionary<GString, Variant>,
        body: PackedByteArray,
    ) {
        let mut hdrs: Vec<(String, String)> = Vec::new();
        for (k, v) in headers.iter_shared() {
            let kk = k.to_string();
            let vv: String = v.to_string();
            hdrs.push((kk, vv));
        }
        // 优化：使用 to_vec() 替代逐字节 push
        let body_vec = body.to_vec();
        self.core.send_response_raw(id as u64, status as u16, hdrs, body_vec);
    }
}
