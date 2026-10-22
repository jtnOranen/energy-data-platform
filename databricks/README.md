# databricks

Databricks Asset Bundle for the bronze load (phase 2): the job `bronze_load` reads new files from the
ADLS `landing` container with Auto Loader and appends them to the `energy.bronze` tables. Serverless
jobs compute (ADR 0011), every 6 hours at :30 UTC, one task per source. The tables and their columns are
described in `docs/data-model.md` and the phase 2 spec.

```
databricks.yml            bundle `energy`, target `dev` (host, root path, run_as the CI service principal)
resources/bronze_job.yml  the job: schedule, serverless environment, one wheel task per source
resources/bronze_rebuild_job.yml  manual job: drop a source's tables and checkpoints, reload all
src/energy_bronze/        sources.py (table definitions), metadata.py, load.py (entry point)
tests/                    local Spark against the ingestion's recorded fixtures
```

## Deploy

CI deploys on every push to `main` that touches `databricks/` (`.github/workflows/databricks.yml`),
as the CI service principal with GitHub OIDC. Don't deploy from your own machine: the bundle's root
path and `run_as` are the service principal's.

Validate locally (as yourself, through `az login`):

```bash
cd databricks
DATABRICKS_AUTH_TYPE=azure-cli databricks bundle validate -t dev
```

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
