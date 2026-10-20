"""FMI open data (WFS) client (docs/data-sources.md)."""

from collections.abc import Iterator
from datetime import datetime, timedelta
from types import TracebackType

import httpx

from energy_ingest.transport import Page, RateLimiter, SourceError, get_with_retry
from energy_ingest.window import iso_z, split

BASE_URL = "https://opendata.fmi.fi/wfs"
STORED_QUERY = "fmi::observations::weather::timevaluepair"
PARAMETERS = "t2m,ws_10min"
MAX_SPAN = timedelta(hours=168)  # longer ranges are rejected with HTTP 400
# FMI's request limits are not verified yet (docs/data-sources.md), so space requests out:
# the backfill makes a few hundred of them.
MIN_INTERVAL_S = 1.0

# fmisid -> short name, verified against the API (station name in the response).
STATIONS = {
    100968: "helsinki_vantaa",
    101786: "oulu",
    101462: "vaasa",
    101044: "pori",
}


class FmiClient:
    def __init__(
        self, client: httpx.Client | None = None, limiter: RateLimiter | None = None
    ) -> None:
        self._client = client or httpx.Client(timeout=120)
        self._limiter = limiter or RateLimiter(MIN_INTERVAL_S)

    def __enter__(self) -> "FmiClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self._client.close()

    def fetch(self, fmisid: int, start: datetime, end: datetime) -> Iterator[Page]:
        """Yield one raw response per chunk of at most 168 hours."""
        for number, (chunk_start, chunk_end) in enumerate(split(start, end, MAX_SPAN), start=1):
            response = get_with_retry(
                self._client,
                BASE_URL,
                params={
                    "service": "WFS",
                    "version": "2.0.0",
                    "request": "getFeature",
                    "storedquery_id": STORED_QUERY,
                    "fmisid": fmisid,
                    "parameters": PARAMETERS,
                    # Without timestep the API returns 1-minute data, ten times larger.
                    "timestep": 10,
                    "starttime": iso_z(chunk_start),
                    "endtime": iso_z(chunk_end),
                },
                limiter=self._limiter,
            )
            _check(response, fmisid)
            yield Page(
                number=number,
                content=response.content,
                record_count=response.content.count(b"<wml2:MeasurementTVP>"),
            )


def _check(response: httpx.Response, fmisid: int) -> None:
    if response.status_code != 200 or b"ExceptionReport" in response.content:
        raise SourceError(
            f"fmi fmisid={fmisid} HTTP {response.status_code}: {_exception_text(response.text)}"
        )


def _exception_text(text: str) -> str:
    texts = []
    remaining = text
    while "<ExceptionText>" in remaining:
        _, _, remaining = remaining.partition("<ExceptionText>")
        message, _, remaining = remaining.partition("</ExceptionText>")
        texts.append(message.strip())
    return " | ".join(texts[:2]) or text[:200]
