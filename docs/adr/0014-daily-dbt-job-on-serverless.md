# 0014 — dbt runs once a day as a job task on serverless compute

- Status: accepted
- Date: 2026-10-22

## Context

dbt needs somewhere to run its CLI and a SQL engine for the SQL it generates. `docs/architecture.md`
sketched one Databricks workflow: the Auto Loader tasks, then a dbt task. Bronze loads every 6 hours
(phase 2). The smallest serverless SQL warehouse (2X-Small) uses 4 DBU/hour, roughly $2.80/hour at list
price, and a build of this project should take a few minutes plus the auto-stop delay: about
$0.20–0.30 per run. The monthly budget for the whole platform is 20 €.

## Options

1. dbt task in `bronze_load`, after the three bronze tasks, every 6 hours — fresher gold; about
   $25–35/month for the warehouse alone, more than the budget.
2. A separate dbt job once a day, after one bronze load — gold is up to a day old; about $6–9/month.
3. dbt run from GitHub Actions against the warehouse — no Databricks job, but orchestration and run
   history split between two systems, and the CI identity would run production.

For the compute: the dbt task's CLI runs on serverless jobs compute (no cluster to size, as in
ADR 0011), and the SQL on a serverless SQL warehouse (starts in seconds, stops itself).

## Decision

Option 2: a job `dbt_build` in the Asset Bundle with one dbt task on serverless jobs compute and a
2X-Small serverless SQL warehouse (one cluster, shortest auto-stop), scheduled daily at 07:15 UTC,
after the 06:30 bronze load. The day-ahead price is published once a day and the analysis is
historical, so a daily gold loses nothing the report needs.

## Consequences

- The two jobs are coupled only by time. If bronze is late or fails, dbt builds what is there and
  `dbt source freshness` (run last) fails the job visibly.
- Gold can lag landing by about a day. Moving to option 1 is a small bundle change if the cost allows.
- Warehouse DBUs are billed to the workspace in `rg-energy-dev`, so the budget alerts cover them.
  Record the actual cost after a week (phase 3 acceptance).
