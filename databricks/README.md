# databricks

Databricks Asset Bundle for the bronze load (phase 2): the job `bronze_load` reads new files from the
ADLS `landing` container with Auto Loader and appends them to the `energy.bronze` tables. Serverless
jobs compute (ADR 0011), every 6 hours at :30 UTC, one task per source. The tables and their columns are
described in `docs/data-model.md` and the phase 2 spec.

```
databricks.yml            bundle `energy`, target `dev` (host, root path, run_as the CI service principal)
resources/bronze_job.yml  the job: schedule, serverless environment, one wheel task per source
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

## Rebuild a table from landing

Landing is immutable, so a bronze table can always be rebuilt. For example, for `fmi_observations`
(in a SQL editor or notebook, as a principal that may drop the table, i.e. the CI service principal
or an admin):

```sql
DROP TABLE energy.bronze.fmi_observations;
```

then delete the checkpoint directory `/Volumes/energy/bronze/checkpoints/fmi_observations` (Catalog
Explorer → volume → delete folder) and run the `fmi` task. The next run reads every file again.

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
