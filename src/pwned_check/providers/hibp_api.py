"```python
HIBP Pwned Passwords Range API provider (k-anonymity, no API key).
"""
from __future__ import annotations
import urllib.request
import urllib.error
from .base import PwnedProvider, NetworkError

_ENDPOINT = "https://api.pwnedpasswords.com/range/"
_UA = "pwned-check/0.1 (+https://github.com/phillipmcmahon/pwned-check)"


class HibpApiProvider(PwnedProvider):
    def __init__(self, timeout: float = 5.0):
        self.timeout = timeout

    def lookup(self, prefix: str, suffix: str) -> int:
        req = urllib.request.Request(
            _ENDPOINT + prefix,
            headers={"User-Agent": _UA, "Add-Padding": "true"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
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
