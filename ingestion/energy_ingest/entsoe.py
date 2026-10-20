"""ENTSO-E Transparency Platform client: day-ahead prices for Finland (docs/data-sources.md)."""

import logging
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from types import TracebackType

import httpx

from energy_ingest.transport import Page, RateLimiter, SourceError, get_with_retry
from energy_ingest.window import split

BASE_URL = "https://web-api.tp.entsoe.eu/api"
BIDDING_ZONE_FI = "10YFI-1--------U"
DOCUMENT_TYPE_PRICES = "A44"
# The API rejects ranges longer than P1Y for prices; 365 days stays under it in leap years too.
MAX_SPAN = timedelta(days=365)
# 400 requests / minute per token; stay well below it.
MIN_INTERVAL_S = 0.5

# The token is a query parameter, and httpx logs every request URL at INFO. Keep httpx at
# WARNING so the token never reaches App Insights or a terminal.
logging.getLogger("httpx").setLevel(logging.WARNING)


class EntsoeClient:
    def __init__(
        self,
        token: str,
        client: httpx.Client | None = None,
        limiter: RateLimiter | None = None,
    ) -> None:
        self._token = token
        self._client = client or httpx.Client(timeout=120)
        self._limiter = limiter or RateLimiter(MIN_INTERVAL_S)

    def __enter__(self) -> "EntsoeClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self._client.close()

    def fetch_prices(self, start: datetime, end: datetime) -> Iterator[Page]:
        """Yield one raw price document per chunk of at most 365 days.

        The API returns whole delivery days (CET) that overlap the requested window.
        """
        for number, (chunk_start, chunk_end) in enumerate(split(start, end, MAX_SPAN), start=1):
            response = get_with_retry(
                self._client,
                BASE_URL,
                params={
                    "securityToken": self._token,
                    "documentType": DOCUMENT_TYPE_PRICES,
                    "in_Domain": BIDDING_ZONE_FI,
                    "out_Domain": BIDDING_ZONE_FI,
                    "periodStart": _period(chunk_start),
                    "periodEnd": _period(chunk_end),
                },
                limiter=self._limiter,
            )
            _check(response)
            yield Page(
                number=number,
                content=response.content,
                record_count=response.content.count(b"<Point>"),
            )


def _period(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y%m%d%H%M")


def _check(response: httpx.Response) -> None:
    """Reject anything that isn't a price document.

    "No data" comes back as HTTP 200 with an Acknowledgement_MarketDocument, so the status code
    alone isn't enough. The message never includes the request URL, which carries the token.
    """
    head = response.content[:500]
    if response.status_code == 200 and b"Publication_MarketDocument" in head:
        return
    reason = _acknowledgement_reason(response.content) if b"Acknowledgement" in head else ""
    raise SourceError(f"entsoe HTTP {response.status_code}: {reason or response.text[:200]}")


def _acknowledgement_reason(content: bytes) -> str:
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return ""
    texts = [el.text for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text" and el.text]
    return " | ".join(texts)
