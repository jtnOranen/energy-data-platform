# databricks

Databricks Asset Bundle for the platform's jobs:

- `bronze_load` (phase 2) reads new files from the ADLS `landing` container with Auto Loader and
  appends them to the `energy.bronze` tables. Serverless jobs compute (ADR 0011), every 6 hours at
  :30 UTC, one task per source. The tables and their columns are described in `docs/data-model.md`
  and the phase 2 spec.
- `dbt_build` (phase 3) runs the dbt project in `../dbt` once a day at 07:15 UTC: silver and gold
  (ADR 0014). See `dbt/README.md`.

```
databricks.yml            bundle `energy`, target `dev` (host, root path, run_as the CI service
                          principal); syncs ../dbt as well
resources/bronze_job.yml  the job: schedule, serverless environment, one wheel task per source
resources/bronze_rebuild_job.yml  manual job: drop a source's tables and checkpoints, reload all
resources/dbt_job.yml     the dbt job: one dbt task on serverless, the project's own profiles.yml
src/energy_bronze/        sources.py (table definitions), metadata.py, load.py (entry point)
tests/                    local Spark against the ingestion's recorded fixtures
```

## Deploy

CI deploys on every push to `main` that touches `databricks/` or `dbt/`
(`.github/workflows/databricks.yml`), as the CI service principal with GitHub OIDC. Don't deploy from your own machine: the bundle's root
path and `run_as` are the service principal's.

Validate locally (as yourself, through `az login`). The bundle needs the alert address, which isn't
in the repository (it's public); CI takes it from the `ALERT_EMAIL` repository variable:

```bash
cd databricks
export BUNDLE_VAR_alert_email=<your email>
DATABRICKS_AUTH_TYPE=azure-cli databricks bundle validate -t dev
```

## Alerts

`bronze_load`, `dbt_build` and `bronze_rebuild` email the owner when a run fails after its retries;
the two scheduled jobs also warn when a run passes 30 minutes. A failing `dbt_build` includes stale
data (`dbt source freshness` runs last). Function failures alert from Azure Monitor
(`infra/modules/monitoring`).

## Run the job once by hand

```bash
DATABRICKS_AUTH_TYPE=azure-cli databricks bundle run -t dev bronze_load
```

Or "Run now" on the job in the workspace UI. The first run loads the whole backfill.

## Rebuild a source's tables from landing

Landing is immutable, so bronze can always be rebuilt, e.g. after a schema change. The manual job
`bronze_rebuild` drops one source's tables and checkpoints and reloads every landing file. It runs as
the CI service principal, which owns the tables. Start it between `bronze_load` runs (they run at
:30 every 6 hours and take about 10 minutes):

```bash
DATABRICKS_AUTH_TYPE=azure-cli databricks bundle run -t dev bronze_rebuild --params source=fingrid
```

The task log has one `table=… rows=…` line per table, as in the scheduled job.

## Tests

The Spark tests need pyspark (the root `spark` dependency group) and Java 17. CI has both. Without
Java the tests are skipped. To run them on Windows without installing Java, use a container:

```bash
docker run --rm -v "$(pwd -W):/src:ro" -w /src \
  -e UV_PROJECT_ENVIRONMENT=/tmp/venv -e UV_LINK_MODE=copy -e UV_CACHE_DIR=/tmp/uvcache \
  ghcr.io/astral-sh/uv:python3.13-bookworm-slim bash -c \
  "apt-get update -qq && apt-get install -y -qq openjdk-17-jre-headless >/dev/null && \
   uv sync --locked --group spark -q && uv run --no-sync pytest databricks/tests -p no:cacheprovider"
```

(from the repo root, in Git Bash; `MSYS_NO_PATHCONV=1` if the volume path gets mangled).
