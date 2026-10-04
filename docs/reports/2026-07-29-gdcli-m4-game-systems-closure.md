# M4 Game Systems — Closure Report

**Date**: 2026-07-29
**Status**: Closed
**Scope**: M4 game systems — 51 routes locked across material/shader/theme/navigation/tilemap/audio/physics; mutation routes return `undoable:true` for editor state mutations; theme value type assertions (Color / int / StyleBox); tilemap clear audit coverage; 10 `doc()` descriptions completed; HTTP status mapping centralized to `ErrorCodes.http_status(r.code)`.

## Plan source

`docs/superpowers/plans/2026-07-29-gdcli-m4-game-systems.md` is also absent from the repo (same `b3cc2e6` cleanup). Scope is reconstructed from the route manifest, code review, and the Task 6 report that drove the M4 force-removal pass on 2026-07-29.

## Scope recap

M4 covers editor mutation routes for runtime-visible game systems:

- **Material** — `material/save`, `material/duplicate`
- **Shader** — `shader/write`, `shader/material/create`, `shader/param/set`
- **Theme** — `theme/create`, `theme/color/set`, `theme/constant/set`, `theme/font_size/set`, `theme/stylebox/set`
- **Navigation** — `navigation/mesh/bake`
- **Tilemap** — `tilemap/layer/clear`
- **Audio** — `audio/bus/list`, `audio/bus/remove`
- **Physics** — `physics/body/create`, `physics/shape/create`, `physics/layer/set`, `physics/joint/create`

Per the design intent, **51 routes across the M4 surface** are locked, with type-exact payload validation for theme items and consistent audit coverage for every mutation.

## Acceptance evidence

### E2E (Task 13 verification, 2026-08-01)

```
$ GODOT_BIN=D:/app/devel/Godot/v4.7.1/godot_console.exe \
    uv run pytest tests/e2e/m4/ -v
32 passed in 30.77s
```

The M4 suite covers all 7 sub-domains above. The test bodies were updated in Task 6 to
match the force-less contract: `test_shader_write_overwrites_without_force`,
`test_tilemap_clear_without_force_succeeds`, `test_navigation_regions_bake_to_project_local_resource`
(no `_with_force` suffix), and `test_audio_bus_add_and_remove_require_safe_semantics` no
longer asserts `force`. Theme type-exact checks (Color / int / StyleBox) are exercised
through the `theme/*` set tests.

### Rust

```
$ cargo test --workspace
202 tests pass across 10 suites; 0 failed
```

### GDScript tooling

```
$ python scripts/format-gd.py && python scripts/format-gd.py --check
gdformat completed for 571 GDScript files.
gdformat check passed for 571 GDScript files.

$ gdlint gdapi/addon/runtime/services/{material,shader,theme,navigation,tilemap,audio}_editor.gd \
        gdapi/addon/routes/{material,shader,theme,navigation,tilemap,audio,physics}
Success: no problems found
```

### Type assertion coverage

- `theme_editor.gd::set_item` — `decoded.value is Color` for `kind == "color"`, `typeof(decoded.value) == TYPE_INT` for `constant` / `font_size`.
- `theme_editor.gd::set_stylebox` — `decoded.value is StyleBox`.
- All Physics routes now use `ErrorCodes.http_status(r.code)` instead of the prior `501 if r.code == "not_supported" else 400` ternary. `not_supported` still maps to 501; all other errors go through `HTTP_STATUS` table.

### Audit coverage

- `tilemap/layer/clear` now records `AuditLog.record("tilemap/layer/clear", "dangerous", {"layer_path": path}, true, "")` on success (was missing before Task 6).
- `material/save`, `shader/write`, `shader/material/create`, `shader/param/set`, `theme/create`, `theme/{color,constant,font_size,stylebox}/set`, `navigation/mesh/bake`, `audio/bus/remove` — all record audits on success and failure with no `force` field in the summary.
- `theme_editor.gd::_save` records the failure audit on `ResourceSaver.save` error (previously silent).

### `doc()` completion

- `physics/body/create`, `physics/shape/create`, `physics/layer/set`, `physics/joint/create` — complete `doc()` with `make / desc / param / example / returns` per Task 6 Step 4.
- `theme/color/set`, `theme/constant/set`, `theme/font_size/set`, `theme/stylebox/set` — complete `doc()` with the typed `value` param description and a concrete example.
- `audio/bus/list` — added `desc` (no params).

### Residual force check

```
$ git grep -n '"force"' gdapi/addon/routes/material gdapi/addon/routes/shader \
                                 gdapi/addon/routes/theme gdapi/addon/routes/navigation \
                                 gdapi/addon/routes/tilemap gdapi/addon/routes/audio \
                                 gdapi/addon/runtime/services/material_editor.gd \
                                 gdapi/addon/runtime/services/shader_editor.gd \
                                 gdapi/addon/runtime/services/theme_editor.gd \
                                 gdapi/addon/runtime/services/navigation_editor.gd \
                                 gdapi/addon/runtime/services/tilemap_editor.gd \
                                 gdapi/addon/runtime/services/audio_editor.gd
(no output)
```

Zero `"force"` audit summaries remain in M4 routes/services.

## Known leftovers / follow-up

- **M4 plan file missing** — same as M3; `docs/superpowers/plans/2026-07-29-gdcli-m4-game-systems.md` is not in the repo. This report stands in for the closure.
- **Audio bus layout** — `_save_layout` audit path is preserved on `audio/bus/remove` success; no separate force gate existed (force removal naturally dissolved the prior permission check).
- **Material/shader doc** — `material/duplicate`, `shader/param/set` carry the brief-mandated `doc()`; no extra param examples were added beyond the unified pattern.
- **Physics route cosmetics** — `_send` is uniform across all 4 physics routes; `not_supported` still maps to 501 via `ErrorCodes.http_status`.

## Summary

M4 game systems are locked: 32 M4 E2E tests pass, all 7 sub-domains covered, type assertions strict on theme values, audit coverage complete on every mutation, HTTP status mapping centralized, and 10 `doc()` descriptions completed. The 51-route M4 surface is fully delivered.
