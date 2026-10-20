"""Fetch → write to landing, shared by the timer functions and the backfill."""

import logging
from datetime import datetime
from typing import Protocol

from energy_ingest import entsoe, fingrid, fmi
from energy_ingest.landing import blob_path
from energy_ingest.transport import SourceError
from energy_ingest.window import iso_z

log = logging.getLogger(__name__)


class Writer(Protocol):
    def write(self, path: str, data: bytes) -> None: ...


def ingest_fingrid(
    client: fingrid.FingridClient,
    landing: Writer,
    start: datetime,
    end: datetime,
    ingested_at: datetime,
) -> int:
    """Fetch every Fingrid dataset; a failing dataset doesn't stop the others."""
    errors: list[str] = []
    written = 0
    for dataset_id, name in fingrid.DATASETS.items():
        try:
            for page in client.fetch(dataset_id, start, end):
                path = blob_path("fingrid", name, ingested_at, start, end, page.number, "json")
                landing.write(path, page.content)
                written += 1
                log.info(
                    "source=fingrid dataset=%s window=%s/%s page=%s records=%s blob=%s",
                    name,
                    iso_z(start),
                    iso_z(end),
                    page.number,
                    page.record_count,
                    path,
                )
        except SourceError as exc:
            log.error(
                "source=fingrid dataset=%s window=%s/%s error=%s",
                name,
                iso_z(start),
                iso_z(end),
                exc,
            )
            errors.append(str(exc))
    _raise_if_any("fingrid", errors)
    return written


def ingest_fmi(
    client: fmi.FmiClient,
    landing: Writer,
    start: datetime,
    end: datetime,
    ingested_at: datetime,
) -> int:
    """Fetch every FMI station; a failing station doesn't stop the others."""
    errors: list[str] = []
    written = 0
    for fmisid, station in fmi.STATIONS.items():
        try:
            for page in client.fetch(fmisid, start, end):
                path = blob_path(
                    "fmi",
                    "observations",
                    ingested_at,
                    start,
                    end,
                    page.number,
                    "xml",
                    key=str(fmisid),
                )
                landing.write(path, page.content)
                written += 1
                log.info(
                    "source=fmi station=%s fmisid=%s window=%s/%s part=%s records=%s blob=%s",
                    station,
                    fmisid,
                    iso_z(start),
                    iso_z(end),
                    page.number,
                    page.record_count,
                    path,
                )
        except SourceError as exc:
            log.error(
                "source=fmi station=%s window=%s/%s error=%s",
                station,
                iso_z(start),
                iso_z(end),
                exc,
            )
            errors.append(str(exc))
    _raise_if_any("fmi", errors)
    return written


def ingest_entsoe(
    client: entsoe.EntsoeClient,
    landing: Writer,
    start: datetime,
    end: datetime,
    ingested_at: datetime,
) -> int:
    """Fetch Finnish day-ahead prices. One dataset, so any error fails the run directly."""
    written = 0
    for page in client.fetch_prices(start, end):
        path = blob_path("entsoe", "day_ahead_price", ingested_at, start, end, page.number, "xml")
        landing.write(path, page.content)
        written += 1
        log.info(
            "source=entsoe dataset=day_ahead_price window=%s/%s part=%s points=%s blob=%s",
            iso_z(start),
            iso_z(end),
            page.number,
            page.record_count,
            path,
        )
    return written


def _raise_if_any(source: str, errors: list[str]) -> None:
    # Raising marks the function run as failed in App Insights, after the healthy parts
    # have already been written.
    if errors:
        raise SourceError(f"{source}: {len(errors)} failed: " + "; ".join(errors))
