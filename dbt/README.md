# dbt

bronze → silver → gold for the energy platform (`docs/phases/phase-3-dbt-star-schema.md`,
`docs/data-model.md`). Runs on the serverless SQL warehouse `energy-dev`.

## Setup (from the repo root)

```bash
uv sync --group dbt
cd dbt
export DBT_PROFILES_DIR=.   # profiles.yml lives here and holds no secrets
uv run dbt deps
```

## Run locally (target `dev`)

Writes to your own schemas `dev_silver` and `dev_gold`, never to `silver`/`gold` (see
`macros/generate_schema_name.sql`). Two ways to log in:

- **Browser (OAuth):** just run dbt; the first command opens a login page.
- **Entra ID token from `az`** (no browser, valid about an hour):

  ```bash
  export DBT_DATABRICKS_TOKEN=$(az account get-access-token \
    --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
  ```

  `2ff814a6-…` is the fixed application ID of Azure Databricks, not a secret.

```bash
uv run dbt build                 # models + tests
uv run dbt build -s staging      # one folder
uv run dbt test --select test_type:unit   # unit tests only
uv run dbt source freshness
uv run sqlfluff lint models tests   # needs a login too: the dbt templater compiles
```

## In production (the `dbt_build` job)

The bundle (`databricks/resources/dbt_job.yml`) syncs this folder to the workspace and runs, daily at
07:15 UTC as the CI service principal: `dbt deps`, `dbt build --target prod`,
`dbt source freshness --target prod` (ADR 0014). To run it now, or after a change that needs a
rebuild:

```bash
cd databricks
databricks bundle run -t dev dbt_build
# rebuild the incremental facts from silver (after changing their logic):
databricks bundle run -t dev dbt_build --params build_flags=--full-refresh
```

## Report models (`models/reports/`)

The report questions (`docs/roadmap.md`) and the price-spike anatomy as tested tables in `gold`
(`rpt_*`, contracts enforced). The `energy_report` dashboard selects from them and does no
calculations of its own (phase 5, decision 1); `_exposures.yml` records that dependency, so dbt's
lineage and slim CI see it. They replaced the ad hoc queries phase 3 kept in `analyses/`.

## Targets

| Target | Who | Auth | Schemas |
| --- | --- | --- | --- |
| `dev` | owner, locally | OAuth or `DBT_DATABRICKS_TOKEN` | `dev_silver`, `dev_gold` |
| `ci` | GitHub Actions (`dbt.yml`) | Entra ID token from OIDC | parse and lint only, nothing built |
| `pr` | GitHub Actions on PRs, as the read-only principal | Entra ID token from OIDC | `pr_<n>_silver`, `pr_<n>_gold`: slim CI (`state:modified+ --defer` against the production manifest, facts from the last 30 days); dropped when the PR closes (`dbt-pr-cleanup.yml`) |
| `prod` | the Databricks job (PR E) | `DBT_ACCESS_TOKEN` injected by Databricks | `silver`, `gold` |

## Layout

- `models/staging/`: one model per bronze table, typed and deduplicated (latest fetch wins; ENTSO-E
  per whole delivery period). Views in `silver`.
- `models/intermediate/`: everything aligned to 15-minute intervals (price fill and expansion,
  Fingrid combined, FMI averaged). Views in `silver`, unit tests in `_intermediate.yml`.
- `models/marts/`: the star schema in `gold`, contracts enforced. The two facts are incremental
  (merge, last `lookback_days` = 3 rebuilt each run); `fct_power_15min` comes from a time spine.
- `seeds/weather_stations.csv`: the four FMI stations (names and coordinates from FMI's metadata).
  Edit a row to change a station; `snapshots/weather_station_snapshot.yml` keeps the history.
- `tests/`: singular data tests (each delivery period yields one price per quarter-hour; every
  complete UTC day has 96 rows in the power fact).
- `macros/generate_schema_name.sql`: production names only for `prod`.
- `macros/local_time_keys.sql`: `date_key`/`time_key` in Finnish local time, one rule for both facts.
- `.sqlfluff`: dbt templater, Databricks dialect, lowercase keywords.

## Rebuild

The facts are incremental. After changing their logic, or to reload the whole history:

```bash
uv run dbt build -s marts --full-refresh
```
