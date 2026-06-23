mod queue;
mod http;
mod server;

use godot::prelude::*;

struct GdApiExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GdApiExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    _placeholder: (),
}

#[godot_api]
impl GdApiServer {
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self { _placeholder: () })
    }

    #[func]
    fn start(&mut self, _port_hint: u16) -> i32 {
        godot_error!("[gdapi] start() not yet implemented");
        -1
    }

    #[func]
    fn stop(&mut self) {}

    #[func]
    fn is_running(&self) -> bool {
        false
    }

    #[func]
    fn port(&self) -> i32 {
        -1
    }

    #[func]
    fn poll_request(&mut self) -> Variant {
        Variant::nil()
    }

    #[func]
    fn send_response(
        &mut self,
        _id: i64,
        _status: i64,
        _headers: Dictionary<StringName, Variant>,
        _body: PackedByteArray,
    ) {
    }
}
