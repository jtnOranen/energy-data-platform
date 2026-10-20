from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import pytest

from energy_ingest.landing import blob_path

INGESTED = datetime(2025, 1, 3, 0, 5, 9, tzinfo=UTC)
START = datetime(2025, 1, 1, 0, 0, tzinfo=UTC)
END = datetime(2025, 1, 3, 0, 0, tzinfo=UTC)


def test_path_is_partitioned_by_ingestion_date_and_names_the_window():
    assert blob_path("fingrid", "wind_production", INGESTED, START, END, 1, "json") == (
        "fingrid/wind_production/yyyy=2025/mm=01/dd=03/"
        "20250103T000509Z_20250101T000000Z_20250103T000000Z_p001.json"
    )


def test_key_goes_before_the_part_number():
    path = blob_path("fmi", "observations", INGESTED, START, END, 2, "xml", key="100968")
    assert path.endswith("_20250103T000000Z_100968_p002.xml")


def test_partition_date_is_utc_not_local():
    # 01:30 in Helsinki on 2025-01-03 is still 2025-01-02 in UTC.
    ingested = datetime(2025, 1, 3, 1, 30, tzinfo=ZoneInfo("Europe/Helsinki"))
    assert "/yyyy=2025/mm=01/dd=02/" in blob_path(
        "fmi", "observations", ingested, START, END, 1, "xml"
    )


def test_naive_ingestion_time_is_rejected():
    with pytest.raises(ValueError):
        blob_path("fingrid", "consumption", datetime(2025, 1, 1), START, END, 1, "json")
