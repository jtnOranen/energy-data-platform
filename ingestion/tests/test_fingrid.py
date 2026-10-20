from datetime import UTC, datetime

import httpx
import pytest

from conftest import FakeClock, fixture_bytes
from energy_ingest.fingrid import BASE_URL, FingridClient
from energy_ingest.transport import RateLimiter, SourceError

START = datetime(2025, 1, 1, 0, 0, tzinfo=UTC)
END = datetime(2025, 1, 1, 2, 0, tzinfo=UTC)


def make_client(handler, clock: FakeClock | None = None) -> FingridClient:
    clock = clock or FakeClock()
    http = httpx.Client(base_url=BASE_URL, transport=httpx.MockTransport(handler))
    return FingridClient(
        "test-key", client=http, limiter=RateLimiter(2.0, clock.clock, clock.sleep)
    )


def recorded_pages(request: httpx.Request) -> httpx.Response:
    page = request.url.params["page"]
    return httpx.Response(
        200,
        content=fixture_bytes(f"fingrid_75_page{page}.json"),
        headers={"content-type": "application/json"},
    )


def test_follows_pagination_and_returns_raw_bytes():
    pages = list(make_client(recorded_pages).fetch(75, START, END, page_size=5))
    assert [p.number for p in pages] == [1, 2]
    assert [p.record_count for p in pages] == [5, 3]
    assert pages[0].content == fixture_bytes("fingrid_75_page1.json")  # unchanged


def test_sends_key_header_and_utc_window():
    seen = []

    def handler(request):
        seen.append(request)
        return recorded_pages(request)

    list(make_client(handler).fetch(75, START, END, page_size=5))
    assert seen[0].headers["x-api-key"] == "test-key"
    assert seen[0].url.path == "/api/datasets/75/data"
    assert seen[0].url.params["startTime"] == "2025-01-01T00:00:00Z"
    assert seen[0].url.params["endTime"] == "2025-01-01T02:00:00Z"


def test_waits_two_seconds_between_requests():
    clock = FakeClock()
    list(make_client(recorded_pages, clock).fetch(75, START, END, page_size=5))
    assert clock.sleeps == [2.0]


def test_retries_429_honouring_retry_after(monkeypatch):
    sleeps = []
    monkeypatch.setattr("energy_ingest.transport.time.sleep", sleeps.append)
    responses = iter([httpx.Response(429, headers={"Retry-After": "7"})])

    def handler(request):
        return next(responses, None) or recorded_pages(request)

    pages = list(make_client(handler).fetch(75, START, END, page_size=5))
    assert len(pages) == 2
    assert 7.0 in sleeps


def test_large_results_without_next_page_keep_paging_while_pages_are_full():
    # Shape seen in a real backfill: no total/lastPage/nextPage, only currentPage/perPage/from/to.
    sizes = {1: 3, 2: 3, 3: 1}
    seen = []

    def handler(request):
        page = int(request.url.params["page"])
        seen.append(page)
        rows = [{"startTime": "2024-01-01T00:00:00.000Z"}] * sizes.get(page, 0)
        return httpx.Response(
            200,
            json={
                "data": rows,
                "pagination": {"currentPage": page, "perPage": 3, "from": 0, "to": 3},
            },
        )

    pages = list(make_client(handler).fetch(75, START, END, page_size=3))
    assert [p.record_count for p in pages] == [3, 3, 1]
    assert seen == [1, 2, 3]


def test_full_last_page_without_next_page_does_not_write_an_empty_page():
    def handler(request):
        page = int(request.url.params["page"])
        rows = [{"startTime": "2024-01-01T00:00:00.000Z"}] * (2 if page == 1 else 0)
        return httpx.Response(200, json={"data": rows, "pagination": {"currentPage": page}})

    pages = list(make_client(handler).fetch(75, START, END, page_size=2))
    assert [p.number for p in pages] == [1]


def test_firewall_block_page_gives_a_clear_error():
    def handler(request):
        return httpx.Response(
            403,
            content=b"<html><title>Service unavailable</title></html>",
            headers={"content-type": "text/html"},
        )

    with pytest.raises(SourceError, match="check the API key value in Key Vault"):
        list(make_client(handler).fetch(75, START, END))


def test_unexpected_json_is_an_error():
    def handler(request):
        return httpx.Response(200, json={"message": "something else"})

    with pytest.raises(SourceError, match="unexpected response keys"):
        list(make_client(handler).fetch(75, START, END))
