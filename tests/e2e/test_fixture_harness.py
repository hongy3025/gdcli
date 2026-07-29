"""Behavioral contracts for the shared source-fixture lifecycle."""

import subprocess
from pathlib import Path

import conftest as harness


class _StoppedProcess:
    def __init__(self) -> None:
        self.terminated = False
        self.wait_timeout = None

    def terminate(self) -> None:
        self.terminated = True

    def wait(self, timeout=None) -> int:
        self.wait_timeout = timeout
        return 0


class _HungProcess(_StoppedProcess):
    def __init__(self) -> None:
        super().__init__()
        self.killed = False
        self.wait_calls = 0

    def wait(self, timeout=None) -> int:
        self.wait_calls += 1
        self.wait_timeout = timeout
        if self.wait_calls == 1:
            raise subprocess.TimeoutExpired("godot", timeout)
        return -9

    def kill(self) -> None:
        self.killed = True


def test_source_fixture_teardown_removes_only_runtime_transport_root(
    tmp_path: Path,
) -> None:
    fixture = tmp_path / "fixture_project"
    runtime_root = fixture / ".godot" / "gdapi_runtime"
    generation = runtime_root / "generation.json"
    sibling = fixture / ".godot" / "keep.json"
    generation.parent.mkdir(parents=True)
    generation.write_text('{"generation":"stale"}', encoding="utf-8")
    sibling.write_text("keep", encoding="utf-8")
    process = _StoppedProcess()

    harness._teardown_godot_fixture(process, fixture)

    assert process.terminated is True
    assert process.wait_timeout == 10
    assert not runtime_root.exists()
    assert sibling.read_text(encoding="utf-8") == "keep"


def test_source_fixture_teardown_kills_hung_editor_before_cleanup(
    tmp_path: Path,
) -> None:
    fixture = tmp_path / "fixture_project"
    runtime_root = fixture / ".godot" / "gdapi_runtime"
    runtime_root.mkdir(parents=True)
    process = _HungProcess()

    harness._teardown_godot_fixture(process, fixture)

    assert process.killed is True
    assert process.wait_calls == 2
    assert not runtime_root.exists()
