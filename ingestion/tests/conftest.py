from pathlib import Path

import httpx
import pytest

FIXTURES = Path(__file__).parent / "fixtures"


def fixture_bytes(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


class NoNetwork(httpx.BaseTransport):
    def handle_request(self, request: httpx.Request) -> httpx.Response:
        raise AssertionError(f"unexpected network call: {request.url}")


@pytest.fixture(autouse=True)
def _block_real_http(monkeypatch: pytest.MonkeyPatch) -> None:
    """Any httpx.Client created without an explicit transport fails instead of going online."""
    original = httpx.Client.__init__

    def init(self, *args, **kwargs):
        kwargs.setdefault("transport", NoNetwork())
        original(self, *args, **kwargs)

    monkeypatch.setattr(httpx.Client, "__init__", init)


class FakeLanding:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    def write(self, path: str, data: bytes) -> None:
        assert path not in self.files, f"overwrite of {path}"
        self.files[path] = data


class FakeClock:
    """Deterministic clock + sleep for RateLimiter and retry tests."""

    def __init__(self) -> None:
        self.now = 1000.0
        self.sleeps: list[float] = []

    def clock(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds
