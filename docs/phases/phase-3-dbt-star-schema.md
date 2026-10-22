# Phase 3 — dbt + star schema

## Goal

A dbt project turns the bronze tables into typed, deduplicated silver models and a gold star schema at
a 15-minute grain, with tests, unit tests, model contracts and a snapshot. It runs on a serverless SQL
warehouse as a task in a Databricks job defined in the existing Asset Bundle, deployed from CI.

Done when (from `docs/roadmap.md`): **`dbt build` passes and gold answers the report questions.**

## Out of scope

The dashboard, price-spike analysis, pipeline-health page and alerting (phase 5). Per-PR schemas
(`pr_<number>`) and slim CI with `state:modified+` (phase 4, decision 3). The forecast extension.
No changes to ingestion or bronze, except the job wiring in the bundle.

## Manual prerequisites (owner)

1. `uv sync --group dbt` locally (new dependency group, see deliverable B) and a browser login for dbt's
   OAuth (`auth_type: oauth`, step 0 item 5). Nothing to register.
2. Phase 2 accepted (two scheduled bronze runs, week-1 cost recorded), because the dbt job's cost
   estimate builds on the bronze cost.

## Step 0: verify

Items 1 and 2 were checked on 2026-10-22 while writing this spec. The rest are checked before or in the
PR that needs them, and the outcome is recorded here.

1. **Versions.** dbt-core **1.12.6** and dbt-databricks **1.12.7** are the latest releases on PyPI
   (2026-10-12/14), both `requires-python >= 3.10`, so they run on the root's Python 3.13 locally and
   on serverless environment 6 (Python 3.12) in the job. Pin `dbt-databricks==1.12.7` in both places.
2. **dbt task on serverless jobs compute is supported** (Microsoft Learn, "dbt task for jobs",
   2026-09-11): the dbt CLI runs on serverless jobs compute with `dbt-databricks` from the task's
   environment, the SQL runs on a **serverless or pro SQL warehouse**, and Databricks injects
   `DBT_ACCESS_TOKEN` for the job's run-as principal. Run-as needs `CAN USE` on the warehouse and the
   Unity Catalog privileges the models need.
3. **Profile and project files in the job:** does the task use the project's own `profiles.yml`
   (`profiles_directory`, reading `DBT_ACCESS_TOKEN` and the warehouse's HTTP path from environment
   variables), or a generated one? We need our own target name (`prod`) for the schema macro. And can
   the bundle sync `../dbt` (`sync.paths`) so the task finds the project as workspace files, keeping
   `dbt/` at the repo root as `CLAUDE.md` lays it out? If not, the fallback is a `git_source` task.
4. **Warehouse cost:** a serverless SQL warehouse at 2X-Small uses **4 DBU/hour** (Microsoft Learn
   pricing page). **Auto-stop: confirmed 2026-10-22** (Microsoft Learn, "Create a SQL warehouse"): the
   UI's minimum for serverless is 5 minutes, the API accepts **1 minute**, so the warehouse uses 1.
   Still open: the Azure Premium price per serverless SQL DBU in `swedencentral` (the AWS list price
   is $0.70, about $2.80/hour), recorded with the first week's cost.
5. **Auth:** CI gets an Entra ID token for the Azure Databricks resource after `azure/login` with OIDC
   (`az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`) and passes it to dbt
   as `token`, so no PAT or secret. Locally the owner uses dbt-databricks' `auth_type: oauth`
   (browser login). **Token path confirmed 2026-10-22** with an `az` token: `dbt debug` connects
   (the SQL connector first tries a token exchange, logs a warning, and uses the token as is) and
   `dbt build` ran staging. The `dev` target takes the same token from `DBT_DATABRICKS_TOKEN` when
   set and falls back to OAuth otherwise; the OAuth login is confirmed on the owner's first run.
6. **Data checks on bronze** (SQL on the warehouse, once it exists): does any delivery day have both a
   `PT60M` and a `PT15M` series? Do repeated fetches of a delivery day ever differ (revision number,
   omitted positions)? How many Fingrid records span more than 15 minutes? Are all FMI timestamps on
   10-minute marks? The answers fix the staging rules below or confirm them.
   **Checked 2026-10-22** on the bronze tables:
   - No delivery day has both grains. 639 hourly periods (two 23-hour, one 25-hour) and 387
     quarter-hour periods (one 23-hour, one 25-hour), 2024-01-01 to 2026-10-22.
   - Repeated fetches of a delivery period never differ: one revision each, same points, same prices.
     Deduplicating per period is still the safe rule if ENTSO-E ever republishes.
   - Fingrid: one 30-minute record each in wind (2024-11-15 18:00) and consumption (2025-05-08
     11:30), with no 15-minute records overlapping them, so splitting them is right. Two intervals
     per dataset have different values across fetches: the **newest interval of a fetch is provisional**
     and the next hourly fetch revises it, which "latest fetch wins" handles.
   - FMI: every timestamp is on a 10-minute mark, 224 `NaN`s, no conflicting values; after
     deduplication exactly 144 points per station, parameter and day (no gaps).
   - Prices range from −21.39 to 1,896.00 EUR/MWh.
7. **Price range limits:** the SDAC harmonised minimum and maximum clearing prices, for the range
   test. **Checked 2026-10-22:** ACER decision 02/2026 sets the reference values at −500 and +4,000
   EUR/MWh; the minimum moved to **−600** for delivery from 2026-05-29 after two extreme-price events
   (SDAC communication, 2026-05-07). Both limits move automatically, so the test uses project vars
   (`price_min_eur_mwh`, `price_max_eur_mwh`) and only warns.
8. **sqlfluff:** does the dbt templater need a warehouse connection to lint? **Yes, confirmed
   2026-10-22:** without a token, compiling the first model fails on authentication. The lint job
   uses the OIDC token from item 5. `dbt parse` needs no connection, so it runs for fork PRs too.

## Deliverables

Delivered as small PRs in this order: (A) Terraform: schemas, warehouse, grants; (B) dbt project,
sources and staging, with CI; (C) intermediate models and unit tests; (D) gold, seed and snapshot;
(E) the dbt job in the bundle, the report queries and docs.

### A. Terraform (`infra/`)

In `modules/unity_catalog/`:

- `databricks_schema` **`silver`** and **`gold`** in `energy` (decision 2). The CI service principal
  owns them, like `bronze`. Seeds and the snapshot also go to `silver`.
- Grant the owner **`CREATE_SCHEMA`** on the catalog, so local dbt runs can create and own the
  owner's development schemas (`dev_silver`, `dev_gold`) without any right to change bronze, silver or
  gold. The existing catalog grant already gives `SELECT` on everything.

New module `modules/sql_warehouse/` (it is compute, not catalog):

- `databricks_sql_endpoint` `energy-dev`: serverless (`enable_serverless_compute = true`,
  `warehouse_type = "PRO"`), `cluster_size = "2X-Small"`, `min_num_clusters = 1`,
  `max_num_clusters = 1`, the shortest `auto_stop_mins` the API allows (step 0 item 4), tags.
- `databricks_permissions`: the owner gets `CAN_USE`. The CI SP creates and owns it.
- Output the warehouse ID and HTTP path for the bundle and the dbt profile.

### B. dbt project (`dbt/`)

```
dbt/
├── dbt_project.yml          project `energy`; staging/intermediate → silver, marts → gold
├── profiles.yml             targets `dev` (owner, oauth), `ci` (token), `prod` (job, DBT_ACCESS_TOKEN);
│                            host and http_path from env vars, no secrets in the file
├── packages.yml             dbt_utils, pinned; package-lock.yml committed
├── macros/
│   └── generate_schema_name.sql   prod: `silver`/`gold` as is; other targets: `<target.schema>_<schema>`
├── seeds/
│   └── weather_stations.csv  fmisid, name, latitude, longitude, role (population centre / wind cluster)
├── snapshots/
│   └── weather_station_snapshot.yml   check strategy on the seed (SCD2)
├── models/
│   ├── staging/             one model per bronze table, `_sources.yml` with freshness
│   ├── intermediate/        15-minute alignment
│   └── marts/               the star schema, contracts enforced
├── tests/                   singular tests (96 intervals per complete UTC day)
├── analyses/                one query per report question
└── README.md                run locally, run in the job, rebuild
```

- `dbt-databricks==1.12.7`, `sqlfluff` and `sqlfluff-templater-dbt` go into a new root dependency
  group **`dbt`** (not default, like `spark`). dbt isn't a Python package, so it isn't a uv workspace
  member.
- The schema macro gives `prod` the plain names and every other target a prefix, so the owner's local
  runs (`dev_silver`, `dev_gold`) and phase 4's PR schemas (`pr_<n>_silver`) can never overwrite
  production.
- Materialisations: staging and intermediate are **views** (the data is small: about 100,000 rows per
  Fingrid table, 1.3 million FMI points); marts are **tables**, the two facts **incremental (merge)**.
- `.sqlfluff` at `dbt/`: dbt templater, Databricks dialect, lowercase keywords (`docs/conventions.md`).

**Sources** (`models/staging/_sources.yml`): the five bronze tables, `loaded_at_field: _ingested_at`
(the fetch time, so freshness measures the whole pipeline from the API), **warn after 8 hours, error
after 24 hours** (bronze loads every 6 hours; roadmap backlog).

**Staging** (silver; typed, renamed to the conventions, deduplicated, nothing else):

| Model | Grain (unique key) | Rules |
| --- | --- | --- |
| `stg_fingrid__wind_production` | `interval_start_utc` | `startTime`/`endTime` → `interval_start_utc`/`interval_end_utc`, `value` → `wind_production_mw` (double); latest `_ingested_at` wins |
| `stg_fingrid__consumption` | `interval_start_utc` | same, `consumption_mw` (MWh/h over 15 min = average MW) |
| `stg_fingrid__production` | `interval_start_utc` | same, `production_mw` |
| `stg_entsoe__day_ahead_price` | `interval_start_utc`, `resolution_minutes` | keep **one document per delivery period**: highest `revision_number`, then latest `_ingested_at` (deduplicating whole periods, not single points, because A03 omits positions and mixing points from two fetches could mix their gaps); `interval_start_utc = period_start + (position − 1) × resolution`; `price_eur_mwh` (decimal) |
| `stg_fmi__observations` | `fmisid`, `parameter`, `observed_at_utc` | `NaN` → null; `value` → double; latest `_ingested_at` wins |

Staging tests: `unique` (or `dbt_utils.unique_combination_of_columns`) and `not_null` on the keys;
ENTSO-E `accepted_values`: `in_domain = 10YFI-1--------U`, `currency_unit = EUR`,
`price_measure_unit = MWH`, `curve_type = A03`, `resolution in (PT60M, PT15M)` (roadmap backlog: test,
don't assume); FMI `parameter in (t2m, ws_10min)`.

### C. Intermediate models and unit tests (silver)

| Model | Grain | Logic |
| --- | --- | --- |
| `int_price_15min` | `interval_start_utc` | Per period, generate every position `1 … (period_end − period_start) / resolution` and **forward-fill** the omitted ones from the last present position (position 1 is never omitted, `docs/data-sources.md`). Then expand 60-minute prices to four 15-minute rows; 15-minute prices as is. `price_resolution_minutes` = 60 or 15. If a day has both grains (step 0 item 6), the 15-minute price wins |
| `int_power_15min` | `interval_start_utc` | Full outer join of the three Fingrid models on `interval_start_utc`. A record spanning more than 15 minutes is split into 15-minute intervals with the same MW value (average power applies to each part) |
| `int_weather_15min` | `fmisid`, `interval_start_utc` | Pivot `t2m` → `temperature_c`, `ws_10min` → `wind_speed_ms`; each 15-minute interval averages the 10-minute observations with `interval_start ≤ observed_at < interval_start + 15 min` (two points, then one, alternately), plus `observation_count`. Simple and documented; interpolation would be more exact but harder to explain and to test |

dbt **unit tests** (`unit_tests:` in YAML, fixture rows inline):

- `int_price_15min`: a 60-minute period expands to four rows per hour with the same price; a
  15-minute period passes through; an omitted A03 position is forward-filled, including two in a row
  and one at the end of the period; the spring DST delivery day (23 hours = 92 quarter-hours) and the
  autumn one (25 hours = 100) end at the right UTC interval.
- `int_power_15min`: a 30-minute Fingrid record becomes two intervals; a missing dataset leaves its
  column null instead of dropping the row.
- `int_weather_15min`: the 2-1-2-1 alignment of 10-minute points to quarter-hours; `NaN` (null)
  doesn't count towards the average.

### D. Gold, seed and snapshot (gold)

| Model | Type | Key | Columns |
| --- | --- | --- | --- |
| `fct_power_15min` | fact, incremental merge | `interval_start_utc` | `date_key`, `time_key`, `price_eur_mwh`, `price_resolution_minutes`, `wind_production_mw`, `consumption_mw`, `production_mw` |
| `fct_weather_15min` | fact, incremental merge | `interval_start_utc`, `weather_station_key` | `date_key`, `time_key`, `temperature_c`, `wind_speed_ms`, `observation_count` |
| `dim_date` | dimension | `date_key` (yyyymmdd, **local Finnish date**) | date, year, quarter, month, ISO week, weekday, `is_weekend`, `intervals_in_day` (92/96/100) |
| `dim_time_15min` | dimension, 96 rows | `time_key` (local time of day) | hour, minute, `quarter_of_hour`, label |
| `dim_weather_station` | dimension, SCD2 | `weather_station_key` | `fmisid`, name, coordinates, role, `valid_from`, `valid_to`, `is_current` |

- **The facts are built from a 15-minute time spine** from 2024-01-01 00:00 UTC to the latest interval
  in the inputs, because Fingrid has gaps (`docs/data-sources.md`); measures may be null. Every
  complete UTC day therefore has exactly 96 rows (ADR 0005).
- `date_key` and `time_key` come from the interval start in `Europe/Helsinki`, because the report
  questions are about local days and hours. On the autumn DST day, local 03:00–03:45 occurs twice, so
  two intervals share a `time_key`; that's correct for hour-of-day profiles and documented.
- Weather is a **separate fact** (grain station × interval) rather than four sets of columns in the
  power fact, so adding a station doesn't change the power fact's contract.
- **Incremental merge with a lookback:** each run reprocesses the last 3 days
  (`var('lookback_days', 3)`), more than the 48-hour fetch overlap, so late and revised data
  replaces earlier rows. `--full-refresh` rebuilds from silver.
- **Station metadata** comes from the seed `weather_stations.csv` (we don't ingest FMI station
  metadata); the snapshot turns edits to the seed into SCD2 history, and `fct_weather_15min` points to
  the station version valid at the interval (decision 4).
- **Contracts** (`contract: {enforced: true}`) on all gold models: column names and types, `not_null`
  constraints on keys, `primary_key` constraints (informational in Unity Catalog).

Gold tests: `unique` + `not_null` on the keys; `relationships` from the facts to the dimensions; the
singular test **every complete UTC day has exactly 96 rows** in `fct_power_15min`; `dim_weather_station`
has one current row per `fmisid`; `price_eur_mwh` within the SDAC limits (step 0 item 7; negative
prices are valid); `temperature_c` between −50 and +40 and `wind_speed_ms` between 0 and 60 as
warnings, not errors.

### E. Job, report queries and docs

**The dbt job** in the bundle (`databricks/resources/dbt_job.yml`), run as the CI SP:

- One `dbt_task` on **serverless jobs compute** (environment with `dbt-databricks==1.12.7`) using the
  warehouse from A, `profiles_directory` and `project_directory` per step 0 item 3.
- Commands: `dbt deps`, `dbt build`, `dbt source freshness`. Freshness runs last, so a stale source
  fails the run visibly without stopping gold from updating with what did arrive.
- Schedule: daily at **07:15 UTC** (decision 1). `max_concurrent_runs: 1`, one retry.
- `.github/workflows/databricks.yml` also triggers on `dbt/**` (the bundle deploys the project files).

**CI for `dbt/`** (in the same workflow or a new `dbt.yml`, on PRs and `main`): `uv sync --group dbt`,
`dbt deps`, `dbt parse`, `sqlfluff lint`. No warehouse queries on PRs in this phase (decision 3).

**Report queries** in `dbt/analyses/` (compiled by dbt, run by hand; results recorded in the acceptance
criteria), one per report question in `docs/roadmap.md`:

1. `wind_vs_price.sql`: correlation and a simple linear fit of price on wind production, per year and
   per price grain.
2. `negative_prices.sql`: count and timing of negative-price intervals, with their average wind,
   consumption, hour and weekday against all intervals.
3. `consumption_vs_temperature.sql`: winter (December–February) consumption against the average
   temperature of the four stations, by temperature band.
4. `price_profiles.sql`: average price by local hour and weekday, and the intra-hour spread (max − min
   of the four quarter-hours) before and after 2025-10-01, filtered on `price_resolution_minutes`.

**Docs:**

- `docs/data-model.md`: updated to what is built (three Fingrid staging models, `production_mw`, the
  separate weather fact, alignment rules, the spine).
- `docs/architecture.md`: the dbt job and the warehouse (components, cost controls).
- ADR 0014 (written with this spec): dbt runs once a day as a job task on serverless compute.
- `dbt/README.md`, `CLAUDE.md` commands (dbt group).
- Every model and every gold column has a YAML description; `dbt docs generate` is uploaded as a CI
  artifact (publishing the docs site is phase 6).

## Cost estimate (to confirm in step 0 item 4)

At about $2.80/hour for a 2X-Small serverless warehouse, a build of this size should take a few
minutes plus the auto-stop delay: roughly $0.20–0.30 per run. Four runs a day (with every bronze load)
would be about $25–35/month, more than the whole 20 € budget; one run a day (decision 1) about
$6–9/month. The dbt
CLI itself runs on serverless jobs compute for a minute or two per run. The budget alerts cover the
warehouse (its DBUs are billed to the workspace in `rg-energy-dev`).

## Decisions (made by the owner on 2026-10-22)

1. **dbt runs once a day**, as its own job `dbt_build` at 07:15 UTC after the 06:30 bronze load, not
   after every bronze load as a fourth task in `bronze_load` (as `docs/architecture.md` sketched): the
   price is day-ahead and the analysis historical, so a daily gold is enough, at about a quarter of the
   warehouse cost. Moving to every load later is a small bundle change. See ADR 0014.
2. **Terraform creates `silver` and `gold`**, like `bronze`: the CI SP owns all schemas and the grants
   live in one place. dbt creates only the owner's dev schemas and, in phase 4, the PR schemas.
3. **Parse and lint on PRs in this phase; unit tests and data tests run in the job and locally.** Slim
   CI in `pr_<n>` schemas with deferral to production stays in phase 4, as the roadmap and architecture
   say: unit tests need their parent tables to exist, which is exactly what deferral solves.
4. **Station metadata comes from a seed with a snapshot** (four rows we already know, check strategy),
   so the SCD2 dimension has a real, editable source, instead of a fourth ingestion path for FMI's
   station metadata API.

## Acceptance criteria

- [ ] Step 0 items are resolved and recorded here.
- [ ] `terraform plan` after apply shows no changes.
- [ ] No PAT, client secret or token in the repo or in `profiles.yml`: the job uses the injected
      `DBT_ACCESS_TOKEN`, CI an Entra ID token from OIDC, the owner OAuth.
- [ ] `dbt build` passes in the job (models, seeds, snapshot, data tests, unit tests) and locally
      against `dev_*` schemas; `sqlfluff lint` and `dbt parse` pass in CI.
- [ ] Every complete UTC day from 2024-01-01 has 96 rows in `fct_power_15min`; the number of null
      measures per column is recorded here and matches the known Fingrid gaps.
- [ ] Both price grains are in gold: `price_resolution_minutes` is 60 before 2025-10-01 and 15 after.
- [ ] A second scheduled run updates the last days through the incremental merge without duplicates.
- [ ] The four report queries run on gold; their results are recorded here (short tables or numbers).
- [ ] Warehouse cost for the first week of scheduled runs is recorded, and the total stays within the
      budget.

## Interview notes to capture (in README or ADRs)

- Why deduplicate ENTSO-E per delivery period, not per point, and why forward-fill A03 in silver.
- Why a time spine and null measures instead of dropping missing intervals.
- Why the facts are keyed by UTC but carry local `date_key`/`time_key`, and what the DST days look like.
- Why incremental merge with a 3-day lookback, and when to `--full-refresh`.
- What model contracts enforce on Databricks and what they don't (informational primary keys).
- Why a seed and a snapshot for station metadata.
