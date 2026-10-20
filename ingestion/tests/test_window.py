from datetime import UTC, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from energy_ingest.window import fetch_window, iso_z, split


def test_window_ends_at_last_full_hour_and_spans_48_hours():
    start, end = fetch_window(datetime(2025, 1, 2, 12, 37, 5, tzinfo=UTC))
    assert end == datetime(2025, 1, 2, 12, 0, tzinfo=UTC)
    assert start == datetime(2024, 12, 31, 12, 0, tzinfo=UTC)


def test_window_is_computed_in_utc_whatever_the_input_zone():
    helsinki = ZoneInfo("Europe/Helsinki")
    start, end = fetch_window(datetime(2025, 1, 2, 14, 37, tzinfo=helsinki))  # 12:37 UTC
    assert end == datetime(2025, 1, 2, 12, 0, tzinfo=UTC)


def test_window_across_dst_change_is_exactly_48_hours():
    # EU clocks moved forward on 2025-03-30 at 01:00 UTC; a UTC window must not notice.
    start, end = fetch_window(datetime(2025, 3, 31, 0, 30, tzinfo=ZoneInfo("Europe/Helsinki")))
    assert end - start == timedelta(hours=48)
    assert start.tzinfo == UTC


def test_naive_datetime_is_rejected():
    with pytest.raises(ValueError):
        fetch_window(datetime(2025, 1, 1, 12, 0))


def test_split_covers_the_range_without_gaps_or_overlaps():
    start = datetime(2024, 1, 1, tzinfo=UTC)
    end = datetime(2024, 1, 20, 5, tzinfo=UTC)
    chunks = split(start, end, timedelta(hours=168))
    assert chunks[0][0] == start
    assert chunks[-1][1] == end
    assert all(a[1] == b[0] for a, b in zip(chunks, chunks[1:], strict=False))
    assert all(e - s <= timedelta(hours=168) for s, e in chunks)
    assert len(chunks) == 3


def test_backfill_range_splits_within_fmi_limit():
    chunks = split(
        datetime(2024, 1, 1, tzinfo=UTC), datetime(2026, 10, 20, tzinfo=UTC), timedelta(hours=168)
    )
    assert all(e - s <= timedelta(hours=168) for s, e in chunks)
    assert len(chunks) == 147


def test_iso_z_formats_in_utc():
    assert iso_z(datetime(2025, 1, 1, 2, 0, tzinfo=timezone(timedelta(hours=2)))) == (
        "2025-01-01T00:00:00Z"
    )
