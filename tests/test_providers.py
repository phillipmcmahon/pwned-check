"""Provider parsing tests."""
from io import BytesIO

from pwned_check.providers.hibp_api import HibpApiProvider
from pwned_check.providers.local_service import LocalServiceProvider


class FakeResponse:
    def __init__(self, body: str):
        self.body = body.encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return BytesIO(self.body).read()


def test_hibp_provider_matches_suffix(monkeypatch):
    def fake_urlopen(req, timeout):
        assert req.full_url == "https://api.pwnedpasswords.com/range/ABCDE"
        assert timeout == 1.5
        return FakeResponse("11111111111111111111111111111111111:2\nFFF:0\n")

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    provider = HibpApiProvider(timeout=1.5)
    assert provider.lookup("ABCDE", "11111111111111111111111111111111111") == 2


def test_local_provider_matches_suffix(monkeypatch):
    def fake_urlopen(url, timeout):
        assert url == "http://127.0.0.1:8000/range/ABCDE"
        assert timeout == 2.5
        return FakeResponse("22222222222222222222222222222222222:9\n")

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    provider = LocalServiceProvider("http://127.0.0.1:8000/", timeout=2.5)
    assert provider.lookup("ABCDE", "22222222222222222222222222222222222") == 9
