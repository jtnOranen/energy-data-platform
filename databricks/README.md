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

Validate locally (as yourself, through `az login`). The bundle needs two addresses that aren't in
the repository (it's public); CI takes them from the `ALERT_EMAIL` and `OWNER` repository
variables:

```bash
cd databricks
export BUNDLE_VAR_alert_email=<alert email> BUNDLE_VAR_owner_user_name=<your Databricks user name>
DATABRICKS_AUTH_TYPE=azure-cli databricks bundle validate -t dev
```

(It recommends adding you as `CAN_MANAGE`; that's because you, not the service principal, are the
one validating. CI deploys as the service principal, which is in the permissions.)

## Alerts

`bronze_load`, `dbt_build` and `bronze_rebuild` email the owner when a run fails after its retries;
the two scheduled jobs also warn when a run passes 30 minutes. A failing `dbt_build` includes stale
data (`dbt source freshness` runs last). Function failures alert from Azure Monitor
(`infra/modules/monitoring`).

## Editing the energy report (dashboard)

The same applies to `pipeline_health` (its files are `pipeline_health.*`, its datasets select from
`energy.ops.ops_*`). Both are published dashboards in the bundle; viewers query with their own
credentials (`embed_credentials: false`, so the owner needs read access to what they show, which
they have).

**Where things live**

| What | Where | Changed by |
| --- | --- | --- |
| Layout, visuals, titles, texts | `resources/dashboards/energy_report.lvdash.json` | a PR (exported from the UI or edited by hand) |
| Dashboard settings (warehouse, permissions, publishing) | `resources/energy_report.dashboard.yml` | a PR, by hand |
| Every number the dashboard shows | dbt models `dbt/models/reports/rpt_*` | a PR (dbt) |
| The deployed, published dashboard | workspace, owned by the CI service principal | CI only, on `main` |

The deployed dashboard is view-only for the owner on purpose: the repository is the source of
truth, and a change made only in the UI would be lost on the next deploy (CI warns, see below).

**Pick the way by what you change**

| Change | Way |
| --- | --- |
| Chart type, colours, layout, a new visual on an existing dataset | A. in the UI, then export |
| A title, a text box, a dataset's `select` | B. edit the file |
| A number, a definition, a new column or table | C. dbt first, then A or B |

**A. Visual changes in the UI**

1. Branch: `git checkout -b feat/report-<what>`.
2. In the workspace, open the published `energy_report` and **Clone** it (⋮ menu): the copy lands in
   your folder and is yours to edit. Note its ID from the URL (`…/dashboardsv3/<id>`).
3. Edit the copy in the UI until it looks right.
4. Pull the copy's definition into the repository's file, from `databricks/`:

   ```bash
   export DATABRICKS_AUTH_TYPE=azure-cli
   export BUNDLE_VAR_alert_email=<alert email> BUNDLE_VAR_owner_user_name=<your user name>
   databricks bundle generate dashboard -t dev --existing-id <copy id> --key energy_report \
     --dashboard-dir resources/dashboards --resource-dir resources --force
   ```

   (`--watch` keeps the file in sync while you edit, if you want to see the diff grow.)
5. The command also rewrites `resources/energy_report.dashboard.yml` from the copy's settings;
   keep only the definition change: `git checkout -- resources/energy_report.dashboard.yml`.
6. Check the diff (`git diff resources/dashboards/`): datasets must still be `select … from
   energy.gold.rpt_…`, with no calculations (phase 5, decision 1). Commit, open a PR.
7. After the merge CI deploys and republishes (a push that changes a dashboard file deploys with
   `--force`: the repository wins). Delete your copy.

**B. Small edits in the file**

Edit `resources/dashboards/energy_report.lvdash.json` directly: text boxes are under
`multilineTextboxSpec.lines` (one Markdown string; the dashboard joins the list's items with no
separator, so put `\n\n` between a heading and its text), dataset queries under
`datasets[].queryLines`, page names under `pages[].displayName`. Validate (`databricks bundle validate -t dev`) and open a PR. Layout by
hand is possible but clumsy; use A for that.

**C. Numbers and logic**

Change or add an `rpt_*` model in `dbt/models/reports/` (with its contract and tests in
`_reports.yml`, and in `_exposures.yml` if it's new), build it locally (`dbt build -s
rpt_<name>`, target dev), and open a PR: slim CI builds it in `pr_<n>_gold`. A new model needs a
new dataset (`select * from energy.gold.rpt_<name>`) and its visuals, added with A or B, in the
same PR or the next one once the model is in production.

**Drift warning.** If the published dashboard was edited in the UI (workspace admins can, despite
the view-only permission) and the change never reached the repository:

- on every PR that runs the Databricks checks, the read-only principal compares each deployed
  dashboard's definition with the file on `main`; a difference passes the check with a warning
  annotation and a job summary saying what to do;
- on `main`, `bundle deploy` refuses to overwrite it and the job fails with the same explanation
  in its summary (and GitHub emails the pusher).

To keep the UI change: `databricks bundle generate dashboard --resource energy_report --force`
pulls the deployed version into the file; commit it, and the push deploys with `--force`. To
discard it: commit any change to the dashboard's file (the repository's version then wins).

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
