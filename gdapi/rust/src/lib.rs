pub mod queue;
pub mod http;
pub mod server;

use godot::prelude::*;
use server::ServerCore;

struct GdApiExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GdApiExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    core: ServerCore,
}

#[godot_api]
impl GdApiServer {
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self { core: ServerCore::new() })
    }

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

    #[func]
    fn stop(&mut self) {
        self.core.stop();
    }

    #[func]
    fn is_running(&self) -> bool {
        self.core.is_running()
    }

    #[func]
    fn port(&self) -> i32 {
        self.core.port()
    }

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
                let mut body = PackedByteArray::new();
                for b in req.body {
                    body.push(b);
                }
                dict.set(&GString::from("body"), &body.to_variant());
                dict.to_variant()
            }
        }
    }

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
        let mut body_vec = Vec::with_capacity(body.len());
        for i in 0..body.len() {
            body_vec.push(body.get(i).unwrap_or(0));
        }
        self.core.send_response_raw(id as u64, status as u16, hdrs, body_vec);
    }
}
