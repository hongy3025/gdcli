# Task 7 report — `runtime/node/get` vertical slice

Date: 2026-07-29
Base: `f8eedbe`

## Delivered

- Replaced the `runtime/node/get` editor-local `runtime_node_ops.gd` call with
  `GdApiRuntimeRoute.dispatch(req, res, "runtime/node/get")`.
- Kept the route summary, parameters, and example; clarified the VariantCodec
  return shape for typed values such as `Vector2`.
- Added a focused route-handler test proving the exact operation reaches the
  broker, plus real CLI assertions for `ok:true`, typed `[10.0, 20.0]`, and the
  absence of the editor-local runtime-ops load.
- Improved the M3 success helper's failure diagnostic so a non-zero gdcli exit
  reports the structured stderr response instead of attempting to parse empty
  stdout.

## TDD evidence

RED before the route change:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call -v
1 failed: editor-local route returned not_found for /root/RuntimeMain/ProbeTarget
```

The focused GDScript route test also failed as intended:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v
1 failed: runtime/node/get dispatches through broker — expected 1, got 0
```

GREEN:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v
1 passed, 12 deselected in 6.43s

GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call -v
1 passed in 8.01s

GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/m3/test_runtime_nodes.py -k runtime_node_get -v
2 passed, 4 deselected in 16.20s

GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/m3/test_m3_contract.py::test_runtime_route_documentation_is_complete -v
1 passed in 7.07s
```

`git diff --check`: exit 0.

## Deferred RED / preserved boundaries

- `runtime/node/set`, `runtime/node/call`, and the remaining node routes are
  intentionally still editor-local and remain deferred to the later node
  family migration (including Task 9's three missing routes). The combined
  historical test name is retained, but its Task 7 body now exercises only
  `get` so the required focused command validates this slice.
- No CLI/Rust changes, route-family migrations, direct HTTP/direct GDScript
  test shortcuts, or handoff-owned dirty files were changed or staged.
- Cargo verification was not run because this slice contains no Rust/CLI code.
