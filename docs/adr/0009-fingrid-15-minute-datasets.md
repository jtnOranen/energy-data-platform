# 0009 — Fingrid 15-minute datasets instead of 3-minute real-time data

- Status: accepted
- Date: 2026-10-20

## Context

The analytical grain is 15 minutes (ADR 0005). The original design used Fingrid's real-time datasets
(181 wind, 193 consumption, 192 production), which have 3-minute resolution and would be averaged to
15 minutes in silver. Checking the sources in phase 1 showed that Fingrid also publishes 15-minute
datasets for the same quantities (75, 124, 74). They have been at 15-minute resolution since 2023-06-13,
which covers the whole backfill period from 2024-01-01.

## Options

1. 3-minute real-time datasets, averaged to 15 minutes in silver. Updated every 3 minutes, but this means
   five times the rows and extra silver logic, and the average has to handle missing 3-minute points.
2. 15-minute datasets. Already at the analytical grain and aligned with the 15-minute ENTSO-E price. They
   are based on measurements, with the unmeasured part (about 2 % of capacity) estimated by Fingrid.

## Decision

Option 2: datasets 75 (wind), 124 (consumption) and 74 (production).

## Consequences

`int_power_15min` joins the three series instead of averaging them. A 15-minute update cadence is
enough, since ingestion runs hourly. The datasets' timestamps may mark the end of each interval (as
Fingrid's description of dataset 124 says), so silver must align them to the interval start. Check this
against the API response before writing the staging models.
