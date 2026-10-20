from datetime import UTC, datetime

import pytest

import backfill

REQUIRED = ["--storage-account", "st", "--key-vault", "kv"]


def test_defaults_cover_2024_onwards_and_all_sources():
    args = backfill.parse_args(REQUIRED)
    assert args.start == datetime(2024, 1, 1, tzinfo=UTC)
    assert args.sources == ["fingrid", "entsoe", "fmi"]
    assert args.end.minute == 0 and args.end.tzinfo == UTC  # last full hour


def test_dates_are_utc_and_source_can_be_narrowed():
    args = backfill.parse_args(
        [*REQUIRED, "--source", "fmi", "--start", "2025-01-01", "--end", "2025-02-01"]
    )
    assert args.sources == ["fmi"]
    assert args.start == datetime(2025, 1, 1, tzinfo=UTC)
    assert args.end == datetime(2025, 2, 1, tzinfo=UTC)


def test_end_must_be_after_start():
    with pytest.raises(SystemExit):
        backfill.parse_args([*REQUIRED, "--start", "2025-02-01", "--end", "2025-01-01"])


def test_storage_account_and_key_vault_are_required():
    with pytest.raises(SystemExit):
        backfill.parse_args([])
