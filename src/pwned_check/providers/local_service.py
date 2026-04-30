"""Local / offline provider stub. Will speak to an on-prem mirror of the range API."""
from __future__ import annotations

import urllib.error
import urllib.request

from .base import NetworkError, PwnedProvider


class LocalServiceProvider(PwnedProvider):
    """Speaks the same range contract as HIBP, but against a local URL."""

    def __init__(self, base_url: str, timeout: float = 2.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def lookup(self, prefix: str, suffix: str) -> int:
        url = f"{self.base_url}/range/{prefix}"
        try:
            with urllib.request.urlopen(url, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, TimeoutError) as e:
            raise NetworkError(str(e)) from e
        for line in body.splitlines():
            suf, _, cnt = line.strip().partition(":")
            if suf.upper() == suffix.upper():
                try:
                    return int(cnt)
                except ValueError:
                    return 0
        return 0
