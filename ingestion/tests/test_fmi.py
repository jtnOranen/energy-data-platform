from datetime import UTC, datetime

import httpx
import pytest

from conftest import FakeClock, fixture_bytes
from energy_ingest.fmi import FmiClient
from energy_ingest.transport import RateLimiter, SourceError


def make_client(handler) -> FmiClient:
    clock = FakeClock()
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return FmiClient(client=http, limiter=RateLimiter(1.0, clock.clock, clock.sleep))


def recorded(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, content=fixture_bytes("fmi_100968_1h.xml"))


def test_returns_raw_response_and_counts_points():
    start, end = datetime(2025, 1, 1, 0, tzinfo=UTC), datetime(2025, 1, 1, 1, tzinfo=UTC)
    pages = list(make_client(recorded).fetch(100968, start, end))
    assert len(pages) == 1
    assert pages[0].content == fixture_bytes("fmi_100968_1h.xml")
    assert pages[0].record_count == 14  # 2 parameters x 7 ten-minute points, both ends included


def test_always_asks_for_ten_minute_steps():
    seen = []

    def handler(request):
        seen.append(request)
        return recorded(request)

    list(
        make_client(handler).fetch(
            100968, datetime(2025, 1, 1, tzinfo=UTC), datetime(2025, 1, 1, 1, tzinfo=UTC)
        )
    )
    params = seen[0].url.params
    assert params["timestep"] == "10"
    assert params["fmisid"] == "100968"
    assert params["parameters"] == "t2m,ws_10min"


def test_long_ranges_are_split_into_168_hour_requests():
    seen = []

    def handler(request):
        seen.append(request)
        return recorded(request)

    pages = list(
        make_client(handler).fetch(
            100968, datetime(2025, 1, 1, tzinfo=UTC), datetime(2025, 1, 20, tzinfo=UTC)
        )
    )
    assert len(pages) == len(seen) == 3
    assert seen[1].url.params["starttime"] == "2025-01-08T00:00:00Z"


def test_exception_report_is_an_error_not_data():
    def handler(request):
        return httpx.Response(400, content=fixture_bytes("fmi_exception_too_long.xml"))

    with pytest.raises(SourceError, match="Too long time interval requested"):
        list(
            make_client(handler).fetch(
                100968, datetime(2025, 1, 1, tzinfo=UTC), datetime(2025, 1, 2, tzinfo=UTC)
            )
        )
