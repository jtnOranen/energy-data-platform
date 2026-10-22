# Phase 2 — Databricks + bronze

## Goal

A Databricks workspace with Unity Catalog reads the raw files in `landing` with Auto Loader and appends
them to bronze Delta tables in `energy.bronze`, every 6 hours, as a job defined in a Databricks Asset
Bundle and deployed from CI. No cleaning, typing beyond parsing, or deduplication: that is dbt's job in
phase 3.

Done when (from `docs/roadmap.md`): **bronze tables update automatically.**

## Out of scope

dbt, silver and gold (phase 3), the `silver`/`gold` schemas, the SQL warehouse, the dashboard, alerting
(phase 5). The dbt task in the Databricks workflow is added in phase 3.

## Manual prerequisites (owner)

1. Nothing to register: an Azure Databricks workspace creates the Databricks account on first use. The
   owner (Global Administrator of the tenant) becomes the first account admin.
2. Re-run `infra/bootstrap/bootstrap.sh` after PR A's bootstrap change, before merging it: it creates
   the workspace (needs the `databricks` Azure CLI extension, which the script installs).
3. Databricks CLI (`winget install Databricks.DatabricksCLI`) to validate and run the bundle locally.
4. After the workspace exists, log in once in the browser as the owner.

## Step 0: verify

Done on 2026-10-22 against the official documentation and the Databricks Go SDK source (which both the
CLI and the Terraform provider use). Items 6 and 7 can only be settled by running the code; they are
checked in PRs B and C and the outcome is recorded here.

1. **Workspace creation needs a subscription-level right.** Creating a workspace requires `Contributor`
   or `Owner` on the subscription, or a custom role with
   `Microsoft.Resources/subscriptions/resourceGroups/write`, because the workspace creates its managed
   resource group outside `rg-energy-dev`. The CI service principal has neither (ADR 0007), so the
   **owner creates the workspace in `bootstrap.sh`** and Terraform reads it as a data source (ADR 0012).
2. **Unity Catalog is enabled automatically** for new workspaces, with an auto-provisioned regional
   metastore that has **no metastore admin**. Instead, workspace admins get `CREATE CATALOG`,
   `CREATE EXTERNAL LOCATION`, `CREATE STORAGE CREDENTIAL` and `CREATE CONNECTION` on it, which is
   everything PR B needs. No account-console setup.
3. **Workspace admins:** principals with `Contributor` or `Owner` on the workspace resource are added to
   the workspace `admins` group automatically, but for a service principal only when the client also
   sends an Azure management token (`X-Databricks-Azure-SP-Management-Token`). The SDK's
   `azure-client-secret` auth does; `github-oidc-azure` doesn't (checked in the SDK source). So
   **`bootstrap.sh` adds the CI SP to the workspace `admins` group** through the SCIM API, as the owner.
   Confirmed on 2026-10-22 after bootstrap: the metastore grants the workspace admins group
   `CREATE_CATALOG`, `CREATE_EXTERNAL_LOCATION` and `CREATE_STORAGE_CREDENTIAL` (item 2), and the
   workspace was attached to `metastore_azure_swedencentral` with a default workspace catalog
   `dbw_energy_dev`, which we don't use.
   The same missing management token matters for the storage credential: Unity Catalog can't check
   the caller's Azure role on the access connector, so it requires the **connector's identity to have
   Reader on the connector itself** (found on PR B's first apply, fixed in `modules/databricks`).
4. **Auth from GitHub Actions:** the SDK has an `auth_type` **`github-oidc-azure`**: it requests a GitHub
   ID token with audience `api://AzureADTokenExchange` and exchanges it at Entra ID for a token for the
   Azure Databricks application. It reuses the federated credentials from phase 0 and needs
   `ARM_CLIENT_ID`, `ARM_TENANT_ID` and the workspace `host`. No PAT or client secret. (`github-oidc` is
   a different thing: Databricks' own federation policy, not needed here.)
5. **Serverless compute for jobs is available in `swedencentral`.** Spark's built-in XML reader needs
   DBR 14.3+, which current serverless environments exceed. The job pins **serverless environment 6**
   (Python 3.12, Databricks Connect 19, supported until 2029-09); the wheel requires Python >= 3.12 and
   ruff targets 3.12 for `databricks/`. Local tests use pyspark 4.1, the closest open-source release.
   DBU price: recorded with the first week's cost (acceptance criteria).
6. **Storage roles:** Databricks documents either `Storage Blob Data Contributor` on the account, or
   `Storage Blob Delegator` on the account plus a data role on the container. We scope per container,
   so the access connector also gets **Storage Blob Delegator** on the account (it only allows getting
   a user delegation key; it grants no data access by itself). Whether `Storage Blob Data Reader` is
   enough for the read-only `landing` location wasn't documented; **confirmed on 2026-10-22**: the
   external location validated and was created with only Reader on `landing` (PR #15's apply).
7. **XML parsing:** confirmed with the recorded fixtures (pyspark 4.1.3, Java 17): with an explicit
   schema, Spark's built-in XML reader matches ENTSO-E's default-namespace elements by their plain
   names (`rowTag = Publication_MarketDocument`), and FMI's prefixed names as written
   (`rowTag = wml2:MeasurementTimeseries`, fields `wml2:point`, attribute `_gml:id`). The first job run
   confirms the same on serverless.

## Deliverables

Delivered as small PRs in this order: (A) workspace and Azure resources, (B) Unity Catalog objects,
(C) the bundle and its CI. A and B are separate so the `databricks` provider is added only once the
workspace and the access connector exist and their roles have propagated.

### A. Workspace (bootstrap) and Azure resources (Terraform)

`infra/bootstrap/bootstrap.sh` creates the workspace (ADR 0012), run by the owner:

- `dbw-energy-dev` in `rg-energy-dev`, **Premium** SKU (required for Unity Catalog), **serverless
  compute mode** (ADR 0013): no classic compute plane, so no managed VNet, NAT gateway, public IP or
  DBFS storage. Idempotent like the rest of the script, and it warns if the workspace isn't serverless.
  (The first workspace defaulted to hybrid and was recreated; see ADR 0013.)

Terraform reads it with `data "azurerm_databricks_workspace"` and adds, in a new module
`infra/modules/databricks/`:

- `azurerm_databricks_access_connector` `dbac-energy-dev` with a system-assigned identity. Unity Catalog
  uses it to reach ADLS (architecture.md, security model).

Storage module: new private container **`lake`** in the existing ADLS account for the catalog's managed
tables, volumes and Auto Loader checkpoints. Same account as `landing` to keep one storage account and
one set of network rules; a separate container keeps the rights apart.

Role assignments (inside `rg-energy-dev`):

| Principal | Role | Scope |
| --- | --- | --- |
| Access connector | Storage Blob Delegator | the ADLS account (needed for container-scoped roles, step 0 item 6) |
| Access connector | Storage Blob Data Reader | the `landing` container (bronze never writes there) |
| Access connector | Storage Blob Data Contributor | the `lake` container |

### B. Terraform: Unity Catalog objects (`infra/`)

New module `infra/modules/unity_catalog/` using the `databricks` provider at workspace level, with
`host` from the workspace data source. In CI it authenticates as the same SP as `azurerm`
(`auth_type = "github-oidc-azure"`, step 0 item 4); locally `terraform plan` uses the owner's `az login`:

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
├── pyproject.toml              uv workspace member `energy-bronze` (no runtime dependencies; pyspark
│                               comes from serverless, and from the root's `spark` group in tests)
├── src/energy_bronze/
│   ├── sources.py              one definition per bronze table: landing path, format, explicit schema,
│   │                           reader options, transform (DataFrame → bronze rows)
│   ├── metadata.py             `_ingested_at`, `_source_file`, `_loaded_at`; FMI key from the file name
│   └── load.py                 entry point: `--source fingrid|entsoe|fmi` → Auto Loader stream per table
└── tests/                      local Spark against the ingestion's recorded fixtures
```

The job `bronze_load`:

- Three tasks, **one per source** (`fingrid`, `entsoe`, `fmi`), running in parallel and independently,
  for the same reason as one function per source in phase 1. The Fingrid task loads its three tables.
- **Serverless jobs compute**, standard performance mode, a pinned serverless environment with the
  `energy-bronze` wheel. See ADR 0011.
- Schedule: cron **`0 30 */6 * * ?`, UTC**, i.e. 00:30, 06:30, 12:30 and 18:30, after the ingestion functions
  (:05/:10/:15). `max_concurrent_runs: 1`.
- Each stream: `readStream.format("cloudFiles")` with directory listing (no file notifications: a few
  files per hour don't need Event Grid and queues), an **explicit schema** with `rescuedDataColumn =
  _rescued_data`, the checkpoint in the `checkpoints` volume, `trigger(availableNow=True)`, append to a
  managed Delta table. A run processes every file that arrived since the last one and stops.
- Explicit schemas instead of inference with `addNewColumns` (changed during implementation): the
  formats are known and verified, so a new or renamed source field can't fail the stream (with
  `addNewColumns` the stream stops once on every new field), and anything unexpected is kept in
  `_rescued_data` instead of being dropped. No schema location is needed.
- Within a task, the tables load one after another; one failing table doesn't stop the others, and the
  task fails at the end. Each task retries once after 5 minutes.

Bronze tables (`energy.bronze`; extends `docs/data-model.md`):

| Table | Landing path | One row per | Columns (besides metadata) |
| --- | --- | --- | --- |
| `fingrid_wind_production` | `fingrid/wind_production/` | record in `data[]` | `datasetId`, `startTime`, `endTime`, `value` |
| `fingrid_consumption` | `fingrid/consumption/` | record | same |
| `fingrid_production` | `fingrid/production/` | record | same |
| `entsoe_day_ahead_price` | `entsoe/day_ahead_price/` | `Point` | `document_mrid`, `revision_number`, `time_series_mrid`, `period_start`, `period_end`, `resolution`, `position`, `price_amount` |
| `fmi_observations` | `fmi/observations/` | `MeasurementTVP` | `fmisid` (from the file name key), `parameter` (from the series `gml:id`), `time`, `value` (string, so `NaN` survives) |

Bronze keeps source values exactly as sent: every column is a string (timestamps, numbers, `NaN`) and
staging types them. The only "transformation" is exploding nested arrays into rows, because a
20,000-record Fingrid page as a single row would be useless to query. Fingrid keeps its JSON field
names; the flattened XML fields get plain snake_case names (`price.amount` → `price_amount`), since
dots and namespace prefixes in column names are awkward in SQL.

Metadata columns on every table:

- `_ingested_at`: the fetch time from the file name (`<ingested_at>_…`), not the load time. It's the
  moment the data was true at the source, which is what silver dedupes on ("latest `_ingested_at`
  wins"). Backfilled files carry the backfill time, which is correct for the same reason.
- `_source_file`: `_metadata.file_path`.
- `_loaded_at`: `current_timestamp()` when the row was appended, for debugging and pipeline health.
- `_rescued_data`: added by Auto Loader; fields the explicit schema doesn't expect, as JSON (normally
  null).

Rebuilding a table from landing (documented in `databricks/README.md`): drop the table, delete its
checkpoint directory in the volume, run the task. Landing is immutable, so this is always safe.

Tests (no network, no workspace):

- `_ingested_at` and FMI station parsing from file names;
- Fingrid: a two-page fixture becomes one row per record with the original fields;
- ENTSO-E: the 60- and 15-minute fixtures give one row per `Point` with `resolution` `PT60M`/`PT15M`, and
  omitted A03 positions stay omitted (no filling in bronze);
- FMI: `t2m` and `ws_10min` series become rows with the right `parameter`, `NaN` kept as a string.

Spark tests need pyspark (root dependency group `spark`, not installed by default) and Java. CI has
both; locally they are skipped with a clear message, so `uv run pytest` still works on the owner's
Windows machine. To run them locally without Java, use a Linux container (see `databricks/README.md`).

### D. CI/CD (`.github/workflows/databricks.yml`)

- On PRs touching `databricks/**`, the root `pyproject.toml`/`uv.lock` or the workflow:
  `uv sync --group spark` with Java 17, ruff, pytest, then `databricks bundle validate -t dev` (trusted
  sources only, same gate as `terraform.yml`).
- On push to `main`: the same, then a deploy job in the `dev` environment: `databricks bundle deploy -t dev`
  with OIDC. The existing `environment:dev` federated credential covers it.
- The root `pyproject.toml` adds `databricks` as a workspace member and its tests to `testpaths`.

This pulls part of phase 4 forward, as phase 1 did for the function.

### E. Docs

- `docs/architecture.md`: serverless instead of single-node job clusters (cost controls, components).
- ADRs 0011 (serverless jobs compute) and 0012 (workspace in bootstrap) are written with this spec.
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
3. **Cron at :30 UTC** instead of a file-arrival trigger: predictable, and one run per schedule instead
   of one per source file batch. **Every 6 hours, not hourly** (owner, 2026-10-22, before the first
   deploy): about a sixth of the serverless cost, and no data is lost, because Auto Loader loads every
   file that arrived since the last run and ingestion still runs hourly. The trade-off is that bronze
   lags landing by up to about 6 hours, which the historical analysis doesn't mind; phase 3's source
   freshness thresholds must allow for it. Easy to tighten later (one cron line).
4. **The workspace is created by `bootstrap.sh`**, not Terraform, so the CI service principal keeps no
   subscription-level rights. See ADR 0012.

## Acceptance criteria

- [ ] Step 0 items 3, 6 and 7 are confirmed by running code and recorded here.
- [ ] `terraform plan` after apply shows no changes.
- [ ] No Databricks PAT, client secret or storage key anywhere: CI uses OIDC, UC uses the access connector.
- [ ] `uv run pytest` and ruff pass locally and in CI; `databricks bundle validate` passes in CI.
- [ ] The job is deployed by CI and the first run loads the whole backfill into all five bronze tables.
      Row counts are recorded here and match the landing files (e.g. Fingrid records per dataset ≈ the
      phase 1 backfill counts plus overlap duplicates).
- [ ] Two consecutive scheduled runs succeed; the second appends only rows from new files (checkpoint
      works, nothing is reloaded).
- [ ] Both ENTSO-E grains are in bronze: `resolution` has `PT60M` before 2025-10-01 and `PT15M` after.
- [ ] Cost after a week of scheduled runs is recorded (Azure cost analysis for the workspace), and it is
      within the budget.

## Interview notes to capture (in README or ADRs)

- Why serverless jobs and not a cluster; what "standard performance mode" trades away.
- Why Auto Loader with `availableNow` instead of a continuous stream or a batch read of the whole folder.
- Why bronze explodes arrays but keeps strings, and why `_ingested_at` is the fetch time, not load time.
- How the access connector, storage credential and external location fit together, and why the
  landing location is read-only.
