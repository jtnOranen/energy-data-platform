"""Fetch windows in UTC."""

from datetime import UTC, datetime, timedelta

# Every run re-fetches the last 48 hours, so late and revised values are picked up.
# Downstream deduplicates; see docs/data-sources.md.
OVERLAP = timedelta(hours=48)


def fetch_window(now: datetime, overlap: timedelta = OVERLAP) -> tuple[datetime, datetime]:
    """Return (start, end) ending at the last full hour before `now`, in UTC."""
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    end = now.astimezone(UTC).replace(minute=0, second=0, microsecond=0)
    return end - overlap, end


def split(start: datetime, end: datetime, max_span: timedelta) -> list[tuple[datetime, datetime]]:
    """Split [start, end) into consecutive chunks no longer than `max_span`."""
    if start.tzinfo is None or end.tzinfo is None:
        raise ValueError("start and end must be timezone-aware")
    if end <= start:
        raise ValueError("end must be after start")
    chunks = []
    chunk_start = start
    while chunk_start < end:
        chunk_end = min(chunk_start + max_span, end)
        chunks.append((chunk_start, chunk_end))
        chunk_start = chunk_end
    return chunks


def iso_z(value: datetime) -> str:
    """Format as ISO 8601 UTC with a Z suffix, e.g. 2025-01-01T00:00:00Z."""
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
