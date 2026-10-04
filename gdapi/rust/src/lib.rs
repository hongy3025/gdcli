//! gdapi — Godot GDExtension HTTP 服务器库。
//!
//! 本库实现了 gdapi 的核心功能：在 Godot 游戏运行时启动一个轻量级 HTTP 服务器，
//! 允许外部工具（如 gdcli）通过 HTTP 请求与游戏交互。
//!
//! 模块结构：
//! - `queue`: 请求队列，线程安全地传递 HTTP 请求
//! - `http`: HTTP 协议解析器
//! - `server`: HTTP 服务器核心实现
//! - `process_runner`: shell-free 进程执行器
//!
//! GDExtension 集成：
//! 通过 `#[gdextension]` 宏将 Rust 代码暴露为 Godot 可调用的类 `GdApiServer`。
//! GDScript 可以直接调用 `GdApiServer.create()`、`start()`、`poll_request()` 等方法。

pub mod http;
pub mod process_runner;
pub mod queue;
pub mod server;

use godot::prelude::*;
use http::validate_response_header;
use process_runner::{PollOutcome, ProcessRunnerCore};
use queue::{CancelReason, RequestControl};
use server::ServerCore;
use std::sync::Arc;

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
/// server.start(8080, "mytoken")
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
        Gd::from_object(Self {
            core: ServerCore::new(),
        })
    }

    /// 启动 HTTP 服务器。
    ///
    /// # Arguments
    /// * `port_hint` - 期望的端口号。如果被占用，会尝试其他端口。
    /// * `token` - 认证 token，为空字符串时不校验。
    ///
    /// # Returns
    /// 实际监听的端口号，失败返回 -1
    #[func]
    fn start(&mut self, port_hint: u16, token: GString) -> i32 {
        let token_opt = if token.is_empty() {
            None
        } else {
            Some(token.to_string())
        };
        match self.core.start(port_hint, token_opt) {
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
                dict.set(
                    &GString::from("method"),
                    &Variant::from(GString::from(req.method.as_str())),
                );
                dict.set(
                    &GString::from("path"),
                    &Variant::from(GString::from(req.path.as_str())),
                );
                let mut hdrs = Dictionary::<GString, Variant>::new();
                for (k, v) in req.headers {
                    hdrs.set(
                        &GString::from(k.as_str()),
                        &Variant::from(GString::from(v.as_str())),
                    );
                }
                dict.set(&GString::from("headers"), &hdrs.to_variant());
                // 优化：使用 from slice 替代逐字节 push
                let body = PackedByteArray::from(req.body.as_slice());
                dict.set(&GString::from("body"), &body.to_variant());
                let control = Gd::from_object(GdApiRequestControl { core: req.control });
                dict.set(&GString::from("control"), &control.to_variant());
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
        if id < 0 {
            godot_error!("[gdapi] send_response rejected negative request id: {}", id);
            return;
        }
        if !(100..=599).contains(&status) {
            godot_error!(
                "[gdapi] send_response rejected invalid HTTP status: {}",
                status
            );
            return;
        }
        let mut hdrs: Vec<(String, String)> = Vec::new();
        for (k, v) in headers.iter_shared() {
            let kk = k.to_string();
            let vv: String = v.to_string();
            if let Err(e) = validate_response_header(&kk, &vv) {
                godot_error!("[gdapi] send_response rejected invalid header: {}", e);
                return;
            }
            hdrs.push((kk, vv));
        }
        // 优化：使用 to_vec() 替代逐字节 push
        let body_vec = body.to_vec();
        if let Err(e) = self
            .core
            .send_response_raw(id as u64, status as u16, hdrs, body_vec)
        {
            godot_error!("[gdapi] send_response failed: {}", e);
        }
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiRequestControl {
    core: Arc<RequestControl>,
}

#[godot_api]
impl GdApiRequestControl {
    #[func]
    fn remaining_ms(&self) -> i64 {
        self.core.remaining_ms() as i64
    }

    #[func]
    fn cancellation_reason(&self) -> GString {
        if self.core.remaining_ms() == 0 {
            self.core.cancel(CancelReason::Timeout);
        }
        match self.core.reason() {
            Some(CancelReason::Timeout) => "timeout",
            Some(CancelReason::Disconnected) => "disconnected",
            Some(CancelReason::Shutdown) => "shutdown",
            None => "",
        }
        .into()
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiProcessRunner {
    core: ProcessRunnerCore,
}

#[godot_api]
impl GdApiProcessRunner {
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self {
            core: ProcessRunnerCore::new(),
        })
    }

    #[func]
    fn start(
        &mut self,
        request: Gd<GdApiRequestControl>,
        executable: GString,
        args: PackedStringArray,
        cwd: GString,
        timeout_ms: i64,
        max_output_bytes: i64,
    ) -> i64 {
        let executable = executable.to_string();
        let argv = args
            .to_vec()
            .into_iter()
            .map(|arg| arg.to_string())
            .collect::<Vec<_>>();
        let cwd_path = std::path::PathBuf::from(cwd.to_string());
        match self.core.start_for_request(
            executable.as_str(),
            &argv,
            &cwd_path,
            timeout_ms,
            max_output_bytes,
            Arc::clone(&request.bind().core),
        ) {
            Ok(id) => id,
            Err(err) => {
                godot_error!("[gdapi] process_runner start failed: {}", err);
                -1
            }
        }
    }

    #[func]
    fn poll(&mut self, id: i64) -> Dictionary<GString, Variant> {
        let mut dict = Dictionary::<GString, Variant>::new();
        if id <= 0 {
            return dict;
        }

        match self.core.poll(id) {
            PollOutcome::Running => {
                dict.set(&GString::from("done"), &Variant::from(false));
            }
            PollOutcome::Done(result) => {
                dict.set(&GString::from("done"), &Variant::from(true));
                dict.set(
                    &GString::from("exit_code"),
                    &Variant::from(result.exit_code.unwrap_or(-1) as i64),
                );
                dict.set(
                    &GString::from("timed_out"),
                    &Variant::from(result.timed_out),
                );
                dict.set(
                    &GString::from("cancelled"),
                    &Variant::from(result.cancelled),
                );
                dict.set(
                    &GString::from("stdout"),
                    &Variant::from(GString::from(result.stdout.as_str())),
                );
                dict.set(
                    &GString::from("stderr"),
                    &Variant::from(GString::from(result.stderr.as_str())),
                );
                dict.set(
                    &GString::from("truncated"),
                    &Variant::from(result.truncated),
                );
            }
            PollOutcome::Missing => {}
        }

        dict
    }

    #[func]
    fn cancel(&mut self, id: i64) -> bool {
        if id <= 0 {
            return false;
        }
        self.core.cancel(id)
    }
}
