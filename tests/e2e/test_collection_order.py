"""Contract: pytest collection order must follow the documented buckets.

This test does not start a Godot editor; it asserts the deterministic
reordering policy in `shared_fixture.bucketize`. The policy keeps all
test functions and assertions intact and only changes execution order.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pytest

from e2e.shared_fixture import _classify, bucketize


REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass
class _FakeItem:
    fspath: Path
    name: str = "test_dummy"


def _items(*relative_paths: str) -> list[_FakeItem]:
    return [_FakeItem(fspath=REPO_ROOT / rel) for rel in relative_paths]


def test_classify_puts_contract_tests_in_bucket_0() -> None:
    assert _classify("tests/e2e/test_unified_fixture_contract.py") == 0
    assert _classify("tests/e2e/test_shared_editor_lifecycle.py") == 0
    assert _classify("tests/e2e/test_shared_editor_contract.py") == 0
    assert _classify("tests/e2e/test_collection_order.py") == 0


def test_classify_puts_slow_paths_in_bucket_4() -> None:
    for rel in [
        "tests/e2e/m5/test_export_android.py",
        "tests/e2e/m6/test_process_run.py",
        "tests/e2e/m6/test_bulk_files.py",
        "tests/e2e/m6/test_bulk_deploy.py",
        "tests/e2e/m6/test_network_request.py",
        "tests/e2e/m6/test_runtime_eval.py",
        "tests/e2e/m6/test_eval.py",
    ]:
        assert _classify(rel) == 4, rel


def test_classify_puts_m3_runtime_in_bucket_3() -> None:
    for rel in [
        "tests/e2e/m3/test_runtime_input.py",
        "tests/e2e/m3/test_runtime_nodes.py",
        "tests/e2e/m3/test_runtime_assert_signal.py",
        "tests/e2e/m3/test_runtime_capture.py",
        "tests/e2e/m3/test_runtime_observability.py",
    ]:
        assert _classify(rel) == 3, rel


def test_classify_defaults_to_bucket_2_for_m2_m4_m3_contract() -> None:
    for rel in [
        "tests/e2e/m2/test_m2_contract.py",
        "tests/e2e/m4/test_m4_contract.py",
        "tests/e2e/m3/test_runtime_status.py",
        "tests/e2e/m5/test_m5_smoke.py",
    ]:
        assert _classify(rel) == 2, rel


def test_bucketize_preserves_relative_order_within_buckets() -> None:
    items = _items(
        "tests/e2e/m5/test_export_android.py",  # bucket 4
        "tests/e2e/m2/test_m2_contract.py",  # bucket 2
        "tests/e2e/test_unified_fixture_contract.py",  # bucket 0
        "tests/e2e/m3/test_runtime_input.py",  # bucket 3
        "tests/e2e/m4/test_m4_contract.py",  # bucket 2
    )
    reordered = bucketize(items)
    file_names = [item.fspath.name for item in reordered]
    assert file_names == [
        "test_unified_fixture_contract.py",  # bucket 0
        "test_m2_contract.py",                # bucket 2
        "test_m4_contract.py",                # bucket 2
        "test_runtime_input.py",              # bucket 3
        "test_export_android.py",             # bucket 4
    ]


def test_bucketize_is_idempotent() -> None:
    items = _items(
        "tests/e2e/m5/test_export_android.py",
        "tests/e2e/m2/test_m2_contract.py",
        "tests/e2e/test_unified_fixture_contract.py",
    )
    once = bucketize(items)
    twice = bucketize(once)
    assert [i.fspath.name for i in once] == [i.fspath.name for i in twice]


def test_collection_modifyitems_runs_during_real_collect() -> None:
    """`pytest --collect-only` should see the bucketed order, not the
    raw file-system order. This catches accidental removal of the hook
    in `tests/e2e/conftest.py`.

    `pyproject.toml` injects `-v` into addopts, so we parse the tree
    output and recover the collected `tests/e2e/...` paths in order.
    """
    import re
    import subprocess
    import sys

    result = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/e2e", "--collect-only"],
        cwd=str(REPO_ROOT),
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stderr

    # The default tree format is `<Module path/to/test_X.py>` /
    # `<Function test_foo>` lines. Walk the indented tree and emit each
    # full path in collection order.
    current_module: str | None = None
    collected_paths: list[str] = []
    module_re = re.compile(r"^<Module ([^>]+)>\s*$")
    for line in result.stdout.splitlines():
        m = module_re.match(line.strip())
        if m:
            current_module = m.group(1).replace("\\", "/")
            collected_paths.append(current_module)
    assert current_module is not None, (
        "collection must list at least one module; got: "
        f"{result.stdout[:500]!r}"
    )
    # We only need the source module ordering; the function-level order
    # within a module is the same as on disk.
    buckets = [_classify(p) for p in collected_paths]
    assert buckets[0] == 0, (
        f"first collected module should be in bucket 0, got "
        f"{collected_paths[0]!r} (bucket {buckets[0]})"
    )
    first_b4 = next((i for i, b in enumerate(buckets) if b == 4), len(buckets))
    last_b2 = max((i for i, b in enumerate(buckets) if b == 2), default=-1)
    if last_b2 >= 0 and first_b4 < len(buckets):
        assert first_b4 > last_b2, (
            f"bucket 4 should be collected after bucket 2; "
            f"first_b4={first_b4} last_b2={last_b2}"
        )
