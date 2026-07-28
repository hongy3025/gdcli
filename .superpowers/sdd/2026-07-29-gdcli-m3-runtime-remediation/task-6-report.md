# Task 6 report — unified runtime route adapter

Date: 2026-07-29
Base: `8301411`

## Delivered

- Added `GdApiRuntimeRoute` as the route-handler-compatible async adapter for
  runtime operations. It obtains the registered broker, validates and caps
  operation timeouts, adds the 1-second broker grace, and delegates all
  request ownership to `GdApiRuntimeBroker.request()`.
- Added the stable protocol error-code to HTTP status map, including
  `timeout -> 408`, and kept protocol v1/top-level message handling unchanged.
- Added mutation success/rejection audit plumbing through the existing
  `Engine.get_meta("gdapi_plugin")` hook. Audit payloads recursively redact
  secrets and summarize base64, packed bytes, and large arrays.
- Added response sent-state visibility so the adapter's local completion guard
  and response guard enforce exactly-once HTTP replies.
- Added behavioral GDScript coverage for disconnected broker behavior,
  timeout validation/capping, all error mappings, envelopes, mutation audit,
  recursive redaction, binary/array summaries, and duplicate callbacks.

## TDD evidence

RED with the required Godot 4.7.1 override:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v
1 failed: preload file res://addons/gdapi/runtime/runtime_route.gd does not exist
```

The unqualified command was also attempted and correctly stopped by the
existing Godot version gate because its default selected 4.6.3.

GREEN focused (34 behavioral assertions):

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v
1 passed, 12 deselected in 6.23s
```

GREEN full GDScript unit/debugger matrix:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -v
13 passed in 10.76s
```

`git diff --check`: exit 0.

## Preserved boundaries

- No CLI or Rust changes; Cargo verification was not run because this slice
  changes no Rust code.
- No public route was migrated and no new route was added; Task 7+ route
  migration and Task 9's three routes remain deferred.
- RuntimeProbe dispatch behavior, protocol v1, broker/transport ownership,
  path-safety boundaries, route docs, and existing audit hook ownership remain
  intact for later adapter-backed route migrations.
- Handoff-owned dirty files were neither modified nor staged.

## Deferred RED / later work

- Existing runtime route handlers still call editor-local runtime ops until the
  planned Task 7+ family migrations; this task intentionally provides only the
  adapter plumbing.
- RuntimeProbe operation behavior, full game-process data-plane coverage,
  disconnect/oversize closure, and the three missing node routes remain in
  their later planned tasks.
