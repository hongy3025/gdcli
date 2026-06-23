@tool
extends EditorPlugin

const Router := preload("res://addons/gdapi/runtime/router.gd")
const META_PATH := "res://.godot/gdapi.json"
const PORT_HINT: int = 7890

var _server: GdApiServer
var _router: Router

func _enter_tree() -> void:
    _server = GdApiServer.create()
    var port: int = _server.start(PORT_HINT)
    if port < 0:
        push_error("[gdapi] failed to bind any port in 7890..7953")
        return
    _router = Router.new()
    _router.scan("res://addons/gdapi/routes")
    _write_meta(port)
    set_process(true)
    print("[gdapi] listening on 127.0.0.1:%d (%d routes)" % [port, _router.count()])

func _exit_tree() -> void:
    set_process(false)
    if _server and _server.is_running():
        _server.stop()
    _delete_meta()

func _process(_dt: float) -> void:
    if _server == null or not _server.is_running():
        return
    while true:
        var req: Variant = _server.poll_request()
        if req == null:
            break
        _router.dispatch(req, _server)

func _write_meta(port: int) -> void:
    var lsp_port: int = 6005
    var es := EditorInterface.get_editor_settings()
    if es and es.has_setting("network/language_server/remote_port"):
        lsp_port = int(es.get_setting("network/language_server/remote_port"))
    var meta := {
        "http_port": port,
        "lsp_port": lsp_port,
        "pid": OS.get_process_id(),
        "started_at": Time.get_datetime_string_from_system(true),
        "gdapi_version": "0.2.0",
    }
    var f := FileAccess.open(META_PATH, FileAccess.WRITE)
    if f == null:
        push_error("[gdapi] cannot write " + META_PATH)
        return
    f.store_string(JSON.stringify(meta, "  "))
    f.close()

func _delete_meta() -> void:
    if FileAccess.file_exists(META_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(META_PATH))
