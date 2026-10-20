"""HTTP helpers shared by the source clients: rate limiting and retries."""

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass

import httpx

log = logging.getLogger(__name__)

RETRYABLE = {429, 500, 502, 503, 504}


class SourceError(RuntimeError):
    """A source returned something that must not be written to landing."""


@dataclass(frozen=True)
class Page:
    """One raw response, kept byte for byte."""

    number: int
    content: bytes
    record_count: int


class RateLimiter:
    """Enforces a minimum interval between requests (e.g. Fingrid: 1 request / 2 s per key)."""

    def __init__(
        self,
        min_interval: float,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._min_interval = min_interval
        self._clock = clock
        self._sleep = sleep
        self._last: float | None = None

    def wait(self) -> None:
        if self._last is not None:
            remaining = self._min_interval - (self._clock() - self._last)
            if remaining > 0:
                self._sleep(remaining)
        self._last = self._clock()


def get_with_retry(
    client: httpx.Client,
    url: str,
    *,
    params: dict[str, str | int],
    headers: dict[str, str] | None = None,
    limiter: RateLimiter | None = None,
    max_attempts: int = 5,
    sleep: Callable[[float], None] | None = None,
) -> httpx.Response:
    """GET with retries on 429/5xx (honouring Retry-After). Other statuses are returned as-is."""
    for attempt in range(1, max_attempts + 1):
        if limiter:
            limiter.wait()
        response = client.get(url, params=params, headers=headers)
        if response.status_code not in RETRYABLE or attempt == max_attempts:
            return response
        delay = _retry_delay(response, attempt)
        log.warning(
            "retrying url=%s status=%s attempt=%s delay_s=%.1f",
            url,
            response.status_code,
            attempt,
            delay,
        )
        (sleep or time.sleep)(delay)
    raise AssertionError("unreachable")


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    retry_after = response.headers.get("Retry-After")
    if retry_after and retry_after.isdigit():
        return float(retry_after)
    return min(2.0**attempt, 60.0)
