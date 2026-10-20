"""Fingrid open data client (docs/data-sources.md, ADR 0009)."""

import json
from collections.abc import Iterator
from datetime import datetime
from types import TracebackType

import httpx

from energy_ingest.transport import Page, RateLimiter, SourceError, get_with_retry
from energy_ingest.window import iso_z

BASE_URL = "https://data.fingrid.fi/api"
MAX_PAGE_SIZE = 20_000
# The documented limit is 1 request / 2 s per key, but a live run got HTTP 429 at exactly 2 s
# between requests, so keep a margin.
MIN_INTERVAL_S = 3.0

# Dataset ID -> landing folder name (matches the bronze table names in docs/data-model.md).
DATASETS = {
    75: "wind_production",
    124: "consumption",
    74: "production",
}


class FingridClient:
    def __init__(
        self,
        api_key: str,
        client: httpx.Client | None = None,
        limiter: RateLimiter | None = None,
    ) -> None:
        self._client = client or httpx.Client(base_url=BASE_URL, timeout=60)
        self._headers = {"x-api-key": api_key}
        self._limiter = limiter or RateLimiter(MIN_INTERVAL_S)

    def __enter__(self) -> "FingridClient":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self._client.close()

    def fetch(
        self, dataset_id: int, start: datetime, end: datetime, page_size: int = MAX_PAGE_SIZE
    ) -> Iterator[Page]:
        """Yield every page of [start, end) for one dataset, raw."""
        page = 1
        while True:
            response = get_with_retry(
                self._client,
                f"/datasets/{dataset_id}/data",
                params={
                    "startTime": iso_z(start),
                    "endTime": iso_z(end),
                    "format": "json",
                    "pageSize": page_size,
                    "page": page,
                },
                headers=self._headers,
                limiter=self._limiter,
            )
            body = _parse(response, dataset_id)
            records = len(body["data"])
            if records == 0 and page > 1:
                return  # ran past the end; nothing to write
            yield Page(number=page, content=response.content, record_count=records)
            next_page = _next_page(body["pagination"], page, records, page_size)
            if not next_page:
                return
            page = next_page


def _next_page(pagination: dict, page: int, records: int, page_size: int) -> int | None:
    # For large results Fingrid omits total/lastPage/nextPage and only returns currentPage,
    # perPage, from and to. Then a full page means there may be more.
    if "nextPage" in pagination:
        return pagination["nextPage"]
    return page + 1 if records == page_size else None


def _parse(response: httpx.Response, dataset_id: int) -> dict:
    if response.status_code != 200:
        hint = ""
        if response.status_code == 403 and "text/html" in response.headers.get("content-type", ""):
            hint = " (Fingrid's firewall blocked the request; check the API key value in Key Vault)"
        raise SourceError(
            f"fingrid dataset={dataset_id} HTTP {response.status_code}{hint}: {response.text[:200]}"
        )
    try:
        body = response.json()
    except json.JSONDecodeError as exc:
        raise SourceError(f"fingrid dataset={dataset_id}: response is not JSON") from exc
    if "data" not in body or "pagination" not in body:
        raise SourceError(f"fingrid dataset={dataset_id}: unexpected response keys {list(body)}")
    return body
