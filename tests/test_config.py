"```python
Tests for config loader.
"""
import os
from pwned_check.config import load


def test_defaults(tmp_path, monkeypatch):
    for k in list(os.environ):
        if k.startswith("PWNED_CHECK_"):
            monkeypatch.delenv(k, raising=False)
    cfg = load(None)
    assert cfg.provider == "hibp"
    assert cfg.fail_closed is False


def test_env_override_fail_closed(monkeypatch):
    monkeypatch.setenv("PWNED_CHECK_FAIL_CLOSED", "true")
    cfg = load(None)
    assert cfg.fail_closed is True
