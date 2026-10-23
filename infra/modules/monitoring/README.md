# monitoring

Failure alerts for the ingestion functions (phase 5, deliverable A):

- Action group `ag-<project>-<env>` emailing the owner (`alert_email`, a sensitive variable: the repo
  is public).
- Log alert `alert-<project>-<env>-function-failures` on Application Insights: a function that
  failed **two or more times in three hours** fires (phase 5 spec, decision 4). One rule split by
  function name, evaluated hourly, resolving itself when a window passes without failures. A single
  failed run stays quiet, since the next run's 48-hour window refetches its data.

Not here: Databricks job failures (job email notifications in the bundle), stale data (the daily
dbt job's `source freshness` fails the job, which then emails), budget alerts (`modules/budget`),
failed `main` deploys (GitHub emails the pusher).

Cost: log alerts are billed per monitored time series; $0.50/month each at 15-minute frequency,
the cheapest tier listed, so about $1.50/month for three functions. Emails are free.
