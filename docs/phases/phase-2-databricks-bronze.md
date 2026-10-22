# Phase 2 — Databricks + bronze

## Goal

A Databricks workspace with Unity Catalog reads the raw files in `landing` with Auto Loader and appends
them to bronze Delta tables in `energy.bronze`, once an hour, as a job defined in a Databricks Asset
Bundle and deployed from CI. No cleaning, typing beyond parsing, or deduplication: that is dbt's job in
phase 3.

Done when (from `docs/roadmap.md`): **bronze tables update automatically.**

## Out of scope

dbt, silver and gold (phase 3), the `silver`/`gold` schemas, the SQL warehouse, the dashboard, alerting
(phase 5). The dbt task in the Databricks workflow is added in phase 3.

## Manual prerequisites (owner)

1. Nothing to register: an Azure Databricks workspace creates the Databricks account on first use. The
   owner (Global Administrator of the tenant) becomes the first account admin.
2. Databricks CLI (`winget install Databricks.DatabricksCLI`) to validate and run the bundle locally.
3. After the workspace exists, log in once in the browser as the owner, so the account console and the
   auto-provisioned metastore are reachable (see step 0).

## Step 0: verify

Resolve each **VERIFY** before writing the code that depends on it, and record the results in this file
(as phase 1 did for `docs/data-sources.md`).

1. **Workspace creation with resource-group-scoped rights.** A workspace creates a managed resource group
   (`databricks-rg-…`) outside `rg-energy-dev`. VERIFY that the CI service principal, which has
   `Contributor` only on `rg-energy-dev` (ADR 0007), can still create the workspace, i.e. that the
   Databricks resource provider creates the managed group with its own identity. If it can't, the
   workspace moves to `bootstrap.sh` (same reasoning as ADR 0007) and gets an ADR.
2. **Unity Catalog auto-enablement in `swedencentral`.** VERIFY that a new workspace is attached to an
   auto-provisioned regional metastore, and which privileges a workspace admin gets on it (we need
   `CREATE STORAGE CREDENTIAL`, `CREATE EXTERNAL LOCATION` and `CREATE CATALOG` for the CI principal). If
   the metastore has no admin, decide whether the owner assigns the CI principal (account console) or
   the grants are made once by hand and documented.
3. **Service principal becomes workspace admin.** VERIFY that the CI SP, as `Contributor` on the
   workspace resource, is added as a workspace admin the first time it authenticates with an Entra ID
   token — no SCIM or account-level setup.
4. **Auth from GitHub Actions.** VERIFY that both the Terraform `databricks` provider and the Databricks
   CLI (`bundle deploy`) accept GitHub OIDC through the Azure SP (`auth_type = "github-oidc-azure"` /
   `DATABRICKS_AUTH_TYPE`) with the federated credentials from phase 0, so no Databricks PAT or secret
   is needed.
5. **Serverless jobs** are available in `swedencentral` on the Premium tier, support Auto Loader with
   `trigger(availableNow=True)` and the built-in `xml` format, and reach the ADLS account (no storage
   firewall today). Note which serverless environment version and Spark version we pin, and the price
   per DBU for the standard (cost-optimised) performance mode.
6. **Read-only external location.** VERIFY that an external location created with `read_only = true`
   validates with only `Storage Blob Data Reader` on the `landing` container.
7. **XML parsing.** VERIFY against the recorded fixtures in `ingestion/tests/fixtures/` that Spark's
   built-in XML reader handles the namespaces in the ENTSO-E and FMI documents, and with which `rowTag`.

## Deliverables

Delivered as small PRs in this order: (A) Azure resources, (B) Unity Catalog objects, (C) the bundle
and its CI. A and B are separate because the `databricks` provider needs the workspace to exist before
it can plan anything against it; splitting avoids an unknown provider host on the first plan.

### A. Terraform: workspace, access connector, storage (`infra/`)

New module `infra/modules/databricks_workspace/`, called from `envs/dev/main.tf`:

- `azurerm_databricks_workspace` `dbw-energy-dev`, **Premium** SKU (required for Unity Catalog),
  managed resource group `rg-energy-dev-dbw-managed`, no VNet injection (serverless doesn't use the
  workspace VNet, and VNet injection adds cost and setup for nothing here).
- `azurerm_databricks_access_connector` `dbac-energy-dev` with a system-assigned identity. Unity Catalog
  uses it to reach ADLS (architecture.md, security model).

Storage module: new private container **`lake`** in the existing ADLS account for the catalog's managed
tables, volumes and Auto Loader checkpoints. Same account as `landing` to keep one storage account and
one set of network rules; a separate container keeps the rights apart.

Role assignments (inside `rg-energy-dev`):

| Principal | Role | Scope |
| --- | --- | --- |
| Access connector | Storage Blob Data Reader | the `landing` container (bronze never writes there) |
| Access connector | Storage Blob Data Contributor | the `lake` container |

### B. Terraform: Unity Catalog objects (`infra/`)

New module `infra/modules/unity_catalog/` using the `databricks` provider (workspace level, configured
with `azure_workspace_resource_id`, so it authenticates with the same Entra ID identity as `azurerm`):

- `databricks_storage_credential` `energy-dev-adls` → the access connector.
- `databricks_external_location` `landing` (`abfss://landing@<account>…/`, `read_only = true`) and
  `lake` (`abfss://lake@<account>…/`).
- `databricks_catalog` `energy` with `storage_root` under the `lake` location, so managed tables land in
  our storage, not in a metastore root we don't control.
- `databricks_schema` `energy.bronze` and a managed volume `energy.bronze.checkpoints` for Auto Loader
  checkpoints and schema tracking.
- Grants: the owner gets `USE CATALOG`, `USE SCHEMA` and `SELECT` on `energy` and `READ FILES` on the
  `landing` location (to explore in notebooks). The CI SP owns the objects and runs the job.

`silver` and `gold` schemas are not created here; phase 3 decides whether Terraform or dbt owns them.

### C. Asset Bundle (`databricks/`)

```
databricks/
├── databricks.yml              bundle `energy`, target `dev` (workspace host, run_as the CI SP)
├── resources/
│   └── bronze_job.yml          job `bronze_load`
├── pyproject.toml              uv workspace member `energy-bronze` (pyspark only as a dev dependency)
├── src/energy_bronze/
│   ├── sources.py              one definition per bronze table: landing path, format, reader options,
│   │                           transform (DataFrame → bronze rows), target table
│   ├── metadata.py             `_ingested_at` from the file name, `_source_file`
│   └── load.py                 entry point: `--source fingrid|entsoe|fmi` → Auto Loader stream per table
└── tests/
    └── test_*.py               local Spark against the recorded fixtures
```

The job `bronze_load`:

- Three tasks, **one per source** (`fingrid`, `entsoe`, `fmi`), running in parallel and independently,
  for the same reason as one function per source in phase 1. The Fingrid task loads its three tables.
- **Serverless jobs compute**, standard performance mode, a pinned serverless environment with the
  `energy-bronze` wheel. See ADR 0011.
- Schedule: cron **`0 30 * * * ?`, UTC**, i.e. :30 every hour, after the ingestion functions
  (:05/:10/:15). `max_concurrent_runs: 1`.
- Each stream: `readStream.format("cloudFiles")` with directory listing (no file notifications: a few
  files per hour don't need Event Grid and queues), `cloudFiles.schemaLocation` and the checkpoint in the
  `checkpoints` volume, `schemaEvolutionMode = addNewColumns`, `trigger(availableNow=True)`, append to a
  managed Delta table. A run processes every file that arrived since the last one and stops.

Bronze tables (`energy.bronze`; extends `docs/data-model.md`):

| Table | Landing path | One row per | Columns (besides metadata) |
| --- | --- | --- | --- |
| `fingrid_wind_production` | `fingrid/wind_production/` | record in `data[]` | `datasetId`, `startTime`, `endTime`, `value` |
| `fingrid_consumption` | `fingrid/consumption/` | record | same |
| `fingrid_production` | `fingrid/production/` | record | same |
| `entsoe_day_ahead_price` | `entsoe/day_ahead_price/` | `Point` | document `mRID` and `revisionNumber`, `period_start`, `period_end`, `resolution`, `position`, `price` |
| `fmi_observations` | `fmi/observations/` | `MeasurementTVP` | `fmisid` (from the file name key), `parameter` (from the series `gml:id`), `time`, `value` (string, so `NaN` survives) |

Bronze keeps source field names and values; timestamps stay ISO strings and are typed in staging. The
only "transformation" is exploding nested arrays into rows, because a 20,000-record Fingrid page as a
single row would be useless to query.

Metadata columns on every table:

- `_ingested_at`: the fetch time from the file name (`<ingested_at>_…`), not the load time. It's the
  moment the data was true at the source, which is what silver dedupes on ("latest `_ingested_at`
  wins"). Backfilled files carry the backfill time, which is correct for the same reason.
- `_source_file`: `_metadata.file_path`.
- `_loaded_at`: `current_timestamp()` when the row was appended, for debugging and pipeline health.

Rebuilding a table from landing (documented in `databricks/README.md`): drop the table, delete its
checkpoint directory in the volume, run the task. Landing is immutable, so this is always safe.

Tests (no network, no workspace):

- `_ingested_at` and FMI station parsing from file names;
- Fingrid: a two-page fixture becomes one row per record with the original fields;
- ENTSO-E: the 60- and 15-minute fixtures give one row per `Point` with `resolution` `PT60M`/`PT15M`, and
  omitted A03 positions stay omitted (no filling in bronze);
- FMI: `t2m` and `ws_10min` series become rows with the right `parameter`, `NaN` kept as a string.

Spark tests need Java; they run in CI (Ubuntu runners have it). Locally they are skipped with a clear
message when Java is missing, so `uv run pytest` still works on the owner's Windows machine.

### D. CI/CD (`.github/workflows/databricks.yml`)

- On PRs touching `databricks/**` (or the workflow): `uv sync`, ruff, pytest, then
  `databricks bundle validate -t dev` (trusted sources only, same gate as `terraform.yml`).
- On push to `main`: the same, then a deploy job in the `dev` environment: `databricks bundle deploy -t dev`
  with OIDC. The existing `environment:dev` federated credential covers it.
- The root `pyproject.toml` adds `databricks` as a workspace member and its tests to `testpaths`.

This pulls part of phase 4 forward, as phase 1 did for the function.

### E. Docs

- `docs/architecture.md`: serverless instead of single-node job clusters (cost controls, components).
- ADR 0011 (serverless jobs compute) is written with this spec; more ADRs if step 0 forces them
  (e.g. the workspace moving to `bootstrap.sh`).
- `docs/data-model.md`: bronze columns as above.
- `databricks/README.md`: deploy, run once by hand, rebuild a table.
- Conventions: `dbac-<project>-<env>` for the access connector, `lake` container.

## Carried over from phase 1

Disable shared key access on both storage accounts (open acceptance item in phase 1). Unity Catalog
uses the access connector's identity, so nothing in this phase needs keys. Done as its own `fix/` PR,
ideally before A.

## Decisions (made by the owner on 2026-10-22)

1. **Serverless jobs compute** instead of a classic single-node job cluster. See ADR 0011.
2. **Deploy the bundle from CI in this phase**, same pattern as the function in phase 1.
3. **Hourly cron at :30 UTC** instead of a file-arrival trigger: predictable, one run per hour instead of
   one per source file batch, and matches "hourly, not continuous" in architecture.md.

## Acceptance criteria

- [ ] Every VERIFY in step 0 is resolved and recorded here.
- [ ] `terraform plan` after apply shows no changes.
- [ ] No Databricks PAT, client secret or storage key anywhere: CI uses OIDC, UC uses the access connector.
- [ ] `uv run pytest` and ruff pass locally and in CI; `databricks bundle validate` passes in CI.
- [ ] The job is deployed by CI and the first run loads the whole backfill into all five bronze tables.
      Row counts are recorded here and match the landing files (e.g. Fingrid records per dataset ≈ the
      phase 1 backfill counts plus overlap duplicates).
- [ ] Two consecutive scheduled runs succeed; the second appends only rows from new files (checkpoint
      works, nothing is reloaded).
- [ ] Both ENTSO-E grains are in bronze: `resolution` has `PT60M` before 2025-10-01 and `PT15M` after.
- [ ] Cost after a week of hourly runs is recorded (Azure cost analysis for the workspace), and it is
      within the budget.

## Interview notes to capture (in README or ADRs)

- Why serverless jobs and not a cluster; what "standard performance mode" trades away.
- Why Auto Loader with `availableNow` instead of a continuous stream or a batch read of the whole folder.
- Why bronze explodes arrays but keeps strings, and why `_ingested_at` is the fetch time, not load time.
- How the access connector, storage credential and external location fit together, and why the
  landing location is read-only.
