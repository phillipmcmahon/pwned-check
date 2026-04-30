"```python
CLI integration tests (stubbed provider).
"""
import io
import sys
import pwned_check.cli as cli
from pwned_check.providers.base import PwnedProvider, NetworkError


class CleanProvider(PwnedProvider):
    def lookup(self, p, s): return 0


class PwnedProvider_(PwnedProvider):
    def lookup(self, p, s): return 7


class BrokenProvider(PwnedProvider):
    def lookup(self, p, s): raise NetworkError("boom")


def _run(monkeypatch, provider, stdin="hunter2", env=None):
    env = env or {}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    monkeypatch.setattr(cli, "_build_provider", lambda cfg: provider)
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin + "\n"))
    return cli.main(["--stdin"])


def test_clean_exit_0(monkeypatch):
    assert _run(monkeypatch, CleanProvider()) == 0


def test_pwned_exit_1(monkeypatch):
    assert _run(monkeypatch, PwnedProvider_()) == 1


def test_network_fail_open(monkeypatch):
    assert _run(monkeypatch, BrokenProvider()) == 0


def test_network_fail_closed(monkeypatch):
    assert _run(monkeypatch, BrokenProvider(), env={"PWNED_CHECK_FAIL_CLOSED": "true"}) == 3
