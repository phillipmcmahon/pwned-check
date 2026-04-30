"```python
Core validator - provider-agnostic.
"""
from dataclasses import dataclass
from hashlib import sha1
from .providers.base import PwnedProvider


@dataclass(frozen=True)
class Result:
    pwned: bool
    count: int
    prefix: str


def _hash(password: str) -> tuple[str, str]:
    dig = sha1(password.encode("utf-8")).hexdigest().upper()
    return dig[:5], dig[5:]


def validate(password: str, provider: PwnedProvider) -> Result:
    prefix, suffix = _hash(password)
    count = provider.lookup(prefix, suffix)
    return Result(pwned=count > 0, count=count, prefix=prefix)
