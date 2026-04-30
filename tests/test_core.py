"""Unit tests for core validator using a fake provider."""
from pwned_check.core import _hash, validate
from pwned_check.providers.base import PwnedProvider


class FakeProvider(PwnedProvider):
    def __init__(self, mapping):
        self.mapping = mapping

    def lookup(self, prefix, suffix):
        return self.mapping.get((prefix, suffix), 0)


def test_hash_split():
    prefix, suffix = _hash("password")
    assert len(prefix) == 5
    assert len(suffix) == 35
    assert prefix.isupper()


def test_clean_password():
    res = validate("xY!3h|#93nsdfakljhr3928", FakeProvider({}))
    assert res.pwned is False
    assert res.count == 0


def test_pwned_password():
    prefix, suffix = _hash("password")
    p = FakeProvider({(prefix, suffix): 12345})
    res = validate("password", p)
    assert res.pwned is True
    assert res.count == 12345
