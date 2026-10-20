# 0005 — UTC timestamps and a 15-minute analytical grain

- Status: accepted
- Date: 2026-10-20

## Context

Sources use different resolutions (Fingrid 3 min, FMI 10 min, ENTSO-E 60 min until delivery day 2025-09-30 and
15 min from 2025-10-01). Finnish local time has DST transitions (23- and 25-hour days).

## Decision

- Store and model all timestamps in UTC from bronze onward; convert to Europe/Helsinki only in reporting.
- The gold grain is one row per 15-minute interval. Hourly prices are expanded to four equal 15-minute rows;
  higher-resolution measurements are averaged into 15-minute intervals.
- Keep `price_resolution_minutes` in the fact table so analysis can tell original and expanded prices apart.

## Consequences

Every complete UTC day has exactly 96 rows, which is testable. Local-day reports must handle 92- and 100-interval days.
Comparing intra-hour variation before and after 2025-10-01 must filter on `price_resolution_minutes`.
