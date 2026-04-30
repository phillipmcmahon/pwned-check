"""Config loader: TOML file + env overrides."""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    provider: str = "hibp"
    fail_closed: bool = False
    timeout_seconds: float = 5.0
    local_url: str | None = None


def load(path: Path | None = None) -> Config:
    data: dict = {}
    if path and path.exists():
        with path.open("rb") as f:
            data = tomllib.load(f)
    cfg = Config(
        provider=data.get("provider", "hibp"),
        fail_closed=bool(data.get("fail_closed", False)),
        timeout_seconds=float(data.get("timeout_seconds", 5.0)),
        local_url=data.get("local_url"),
    )
    if v := os.getenv("PWNED_CHECK_PROVIDER"):
        cfg.provider = v
    if v := os.getenv("PWNED_CHECK_FAIL_CLOSED"):
        cfg.fail_closed = v.lower() in {"1", "true", "yes"}
    if v := os.getenv("PWNED_CHECK_TIMEOUT"):
        cfg.timeout_seconds = float(v)
    if v := os.getenv("PWNED_CHECK_LOCAL_URL"):
        cfg.local_url = v
    return cfg
