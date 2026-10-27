# 0017 — Bronze loads once a day, and predictive optimization is off

- Status: accepted
- Date: 2026-10-27

## Context

The monthly budget for the whole platform is 20 €. October's cost forecast reached about 27 €.
Most of it was development (dbt runs, PR builds and dashboard work on the SQL warehouse, 22–24
October), but a quiet day with no development (25 October) still cost about 0.85 €, roughly 26 € a
month. On that day, from `system.billing.usage` and Azure Cost Management:

| Item | DBU | About |
| --- | --- | --- |
| Predictive optimization (serverless jobs SKU) | 0.81 (0.34–0.90 on other days) | 0.15–0.38 € |
| `bronze_load`, 4 runs | 0.69 | 0.29 € |
| SQL warehouse, daily `dbt_build` | 0.23 | 0.18 € |
| `dbt_build` job task, storage, Function, alerts | — | about 0.05 € |

Bronze loaded every 6 hours (phase 2 spec, decision 3), but its only reader is `dbt_build`, once a
day at 07:15 UTC (ADR 0014). Three of the four runs changed nothing anyone sees. Predictive
optimization runs OPTIMIZE and VACUUM on Unity Catalog managed tables; on tables this small,
compaction makes no query noticeably faster.

## Options

1. Keep both as they are: about 26 €/month at rest, over budget.
2. Load bronze once a day at 06:30 UTC, before `dbt_build`, and disable predictive optimization on
   the catalog: about 0.30 €/day, 9 €/month at rest.
3. As 2, and also pause both job schedules between work sessions: close to zero, but the report
   goes stale and the freshness checks stop meaning anything.

## Decision

Option 2. `bronze_load` runs at `0 30 6 * * ?` UTC. The `energy` catalog has
`enable_predictive_optimization = "DISABLE"` in Terraform, which every schema inherits.

## Consequences

- The report is as fresh as before: gold was already rebuilt once a day. Bronze now lags landing by
  up to a day instead of 6 hours. No data is lost: ingestion still runs hourly with a 48-hour
  overlap, and Auto Loader loads every file that arrived since the last run.
- `dbt_build` depends on the 06:30 run alone. There is no earlier run to fall back on, so a bronze run
  more than 45 minutes late makes the newest fetch over 24 hours old and `dbt source freshness`
  fails the job. That is the intended signal, and the failed bronze run emails as well. The source
  freshness thresholds (warn 8 h, error 24 h) stay: at 07:15 bronze is normally about an hour old.
- Without predictive optimization, small files and old table versions are kept. With one bronze
  append and one dbt rebuild a day they grow slowly, and storage in our own ADLS account costs
  cents. Run `OPTIMIZE` or `VACUUM` by hand if a query gets slow or storage grows.
- Option 3 stays available to the owner: pausing loses nothing, and the first run after unpausing
  catches up.
