import logging
from datetime import UTC, datetime

import httpx
import pytest

from conftest import FakeClock, FakeLanding, fixture_bytes
from energy_ingest.entsoe import BIDDING_ZONE_FI, EntsoeClient
from energy_ingest.run import ingest_entsoe
from energy_ingest.transport import RateLimiter, SourceError

TOKEN = "00000000-1111-2222-3333-444444444444"
DAY_START = datetime(2025, 9, 28, 22, tzinfo=UTC)
DAY_END = datetime(2025, 9, 29, 22, tzinfo=UTC)


def make_client(handler) -> EntsoeClient:
    clock = FakeClock()
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return EntsoeClient(TOKEN, client=http, limiter=RateLimiter(0.5, clock.clock, clock.sleep))


def respond(fixture: str, status: int = 200):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status, content=fixture_bytes(fixture), headers={"content-type": "text/xml"}
        )

    return handler


@pytest.mark.parametrize(
    ("fixture", "points"),
    [("entsoe_fi_20250929_pt60m.xml", 24), ("entsoe_fi_20251002_pt15m.xml", 96)],
)
def test_60_and_15_minute_documents_pass_through_unchanged(fixture, points):
    pages = list(make_client(respond(fixture)).fetch_prices(DAY_START, DAY_END))
    assert len(pages) == 1
    assert pages[0].content == fixture_bytes(fixture)
    assert pages[0].record_count == points


def test_request_parameters():
    seen = []

    def handler(request):
        seen.append(request)
        return respond("entsoe_fi_20250929_pt60m.xml")(request)

    list(make_client(handler).fetch_prices(DAY_START, DAY_END))
    params = seen[0].url.params
    assert params["documentType"] == "A44"
    assert params["in_Domain"] == params["out_Domain"] == BIDDING_ZONE_FI
    assert params["periodStart"] == "202509282200"
    assert params["periodEnd"] == "202509292200"
    assert params["securityToken"] == TOKEN


def test_no_data_acknowledgement_with_http_200_is_an_error():
    with pytest.raises(SourceError, match="No matching data found"):
        list(make_client(respond("entsoe_ack_no_data.xml")).fetch_prices(DAY_START, DAY_END))


def test_too_long_range_acknowledgement_is_an_error():
    with pytest.raises(SourceError, match="larger than maximum allowed period"):
        list(make_client(respond("entsoe_ack_too_long.xml", 400)).fetch_prices(DAY_START, DAY_END))


def test_backfill_range_is_split_into_chunks_of_at_most_365_days():
    seen = []

    def handler(request):
        seen.append(request)
        return respond("entsoe_fi_20250929_pt60m.xml")(request)

    list(
        make_client(handler).fetch_prices(
            datetime(2024, 1, 1, tzinfo=UTC), datetime(2026, 10, 20, tzinfo=UTC)
        )
    )
    assert len(seen) == 3
    assert seen[1].url.params["periodStart"] == "202412310000"


def test_token_never_appears_in_logs_or_errors(caplog):
    caplog.set_level(logging.DEBUG)
    landing = FakeLanding()
    ingest_entsoe(
        make_client(respond("entsoe_fi_20250929_pt60m.xml")),
        landing,
        DAY_START,
        DAY_END,
        datetime(2025, 9, 30, tzinfo=UTC),
    )
    with pytest.raises(SourceError) as excinfo:
        list(make_client(respond("entsoe_ack_no_data.xml")).fetch_prices(DAY_START, DAY_END))
    assert TOKEN not in caplog.text
    assert TOKEN not in str(excinfo.value)
    assert not any(TOKEN.encode() in data for data in landing.files.values())


def test_writes_to_entsoe_day_ahead_price_folder():
    landing = FakeLanding()
    written = ingest_entsoe(
        make_client(respond("entsoe_fi_20251002_pt15m.xml")),
        landing,
        DAY_START,
        DAY_END,
        datetime(2025, 9, 30, tzinfo=UTC),
    )
    assert written == 1
    (path,) = landing.files
    assert path.startswith("entsoe/day_ahead_price/yyyy=2025/mm=09/dd=30/")
    assert path.endswith("_p001.xml")
