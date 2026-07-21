import subprocess

import pytest

import conftest


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("4.7.stable.official.123", (4, 7, 0)),
        ("4.7.1.stable.official.123", (4, 7, 1)),
        ("Godot Engine v4.7.2.stable", (4, 7, 2)),
    ],
)
def test_parse_godot_47_versions(text, expected):
    assert conftest.parse_godot_version(text) == expected


@pytest.mark.parametrize("text", ["4.6.3.stable", "3.6.2", "not-a-version"])
def test_require_godot_47_rejects_old_or_invalid(monkeypatch, text):
    completed = subprocess.CompletedProcess(["godot", "--version"], 0, text, "")
    monkeypatch.setattr(conftest.subprocess, "run", lambda *args, **kwargs: completed)
    with pytest.raises(RuntimeError, match="Godot 4.7.x is required"):
        conftest.require_godot_47("godot")