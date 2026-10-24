# Phase 5 — Report + monitoring

## Goal

A Databricks AI/BI dashboard answers the four report questions and the price-spike extension from
gold, and a second dashboard shows the pipeline's health and cost. Failures alert the owner by
email: a failed Databricks job, repeatedly failing ingestion functions, and stale data. Both
dashboards are defined in the Asset Bundle and deployed from CI; the README shows the findings.

Done when (from `docs/roadmap.md`): **dashboard live, failures alert.**

## Out of scope

The forecast extension. Publishing the dbt docs site (phase 6). A second environment. Real-time
or streaming views: gold updates daily (ADR 0014), so the report does too.

## Where we start (checked 2026-10-23)

- Gold answers the report questions: the queries in `dbt/analyses/` ran on 2026-10-23 and their
  results are in the phase 3 spec. They are SQL files, not tested models, and nothing visualises
  them.
- The only alerts are the budget's (actual 80 %/100 %, forecast 100 %). A failed job, function or
  deploy shows only on its own page: ENTSO-E's outage on 2026-10-22 (two failed function runs) was
  found by hand (roadmap backlog). GitHub already emails the person whose push failed a workflow.
- dbt source freshness fails the daily job when bronze is over 24 hours old, but nobody is told.
- Databricks system tables (`system.billing`, `system.lakeflow`) exist, but nobody can read them:
  the auto-provisioned metastore has no metastore admin, so no grants were ever made (owner's query
  on 2026-10-23: "does not have USE SCHEMA on Schema 'system.billing'").

## Manual prerequisites (owner)

1. Make the owner a Databricks **account admin** (corrected during implementation: the spec first
   said metastore admin, which turned out not to be enough; step 0 item 1). Needed once, so
   `bootstrap.sh` can grant access to the system tables. The owner signs in with a personal
   Microsoft account, which the account console doesn't accept (it signs such accounts into
   Microsoft's consumer tenant, "Microsoft Services", not the owner's), so:
   1. in Entra ID, create a temporary native user (`…@<tenant>.onmicrosoft.com`) with the Global
      Administrator role; on its first sign-in at accounts.azuredatabricks.net it becomes
      account admin;
   2. with it, in **User management**, give the owner's user the **Account admin** role (and, in
      **Catalog**, make the owner metastore admin of `metastore_azure_swedencentral`);
   3. delete the temporary user. The owner's account-admin role works from the workspace (SQL and
      API grants), without the console.
2. Build the first draft of each dashboard in the workspace UI with Claude Code's queries, so the
   layout is designed by eye; the bundle then takes over the exported definition (deliverable B).

## Step 0: verify

1. **System tables access:** after prerequisite 1, can the owner grant `USE SCHEMA` and `SELECT` on
   `system.billing` and `system.lakeflow` to the CI service principal (which publishes the
   dashboards and so runs their queries, item 3) and to themselves? Which system schemas need
   enabling first (`lakeflow` may be off by default)? The grants are owner-rights operations, so
   they go into `bootstrap.sh`, not Terraform (the CI principal can't grant on `system`).
   **Checked 2026-10-24:** as metastore admin the owner could list the grants but not change them
   ("PERMISSION_DENIED: User is not an account admin for Account"); as account admin (prerequisite
   1) the grants work, through SQL and through the Unity Catalog API (`PATCH
   /api/2.1/unity-catalog/permissions/schema/system.<schema>`), which `bootstrap.sh` uses because it
   needs no SQL warehouse. `billing` and `lakeflow` were already enabled; `account users` already
   has `USE CATALOG` on `system`, so the two schema grants are all it takes. Both service
   principals get them: the deploying one runs the ops models in the dbt job, the PR one builds
   them in slim CI. The system tables are metastore-wide, so the models filter on this workspace's
   ID. List prices in `swedencentral` (USD per DBU): serverless SQL 0.91, serverless jobs 0.47,
   which also settles phase 3's step 0 item 4.
2. **Dashboards in the bundle:** the `dashboards` resource (`file_path` to a `.lv.json`,
   `warehouse_id`, `embed_credentials`, permissions) and `databricks bundle generate dashboard
   --existing-id` to export a UI draft, with the CLI version CI pins. What happens on deploy when
   the dashboard was edited in the UI since (the bundle warns about remote changes)? And how a CI
   job can tell, before deploying, that the deployed dashboard differs from the repository's file
   (its etag against the one the bundle last deployed, or the serialized content), for the drift
   warning below.
   **Checked 2026-10-24** (CLI v1.21.0 and its source, `check_dashboards_modified_remotely.go`):
   the bundle stores each dashboard's etag at deploy; `bundle deploy` fails with "dashboard … has
   been modified remotely … will be overwritten on deploy" when the deployed etag differs, unless
   `--force`, and `bundle plan` reports the same as a warning. `--force` is needed even after the
   UI edit was pulled into the file, so the CI deploys with `--force` when the push changed a
   dashboard file (the repository wins, as intended) and without it otherwise (a UI edit stops the
   deploy). `bundle generate dashboard --existing-id … --key …` exported both drafts.
3. **Whose rights a published dashboard uses:** with embedded credentials, queries run as the
   publisher, here the CI principal; viewers need only view permission. Confirm that, and that the
   owner can view it. **Checked 2026-10-24:** not possible here. With `embed_credentials: true`
   the bundle's `run_as` must be whoever deploys ("dashboards with embed_credentials set to true
   do not support a setting a run_as user that is different from the owner"), which fails
   validation on PRs (read-only principal) and locally (owner). So `embed_credentials: false`:
   viewers query with their own rights. The owner, the only viewer, reads gold, ops and (as
   account admin) the system tables; another viewer would need those grants.
4. **dbt results in a table:** an `on-run-end` hook gets `results` (status, timing, failures per
   node) in dbt 1.12; confirm the fields and that a macro can insert them into a Delta table in the
   same run, on the job's serverless dbt task.
5. **Function failure alert:** an Azure Monitor log alert (`azurerm_monitor_scheduled_query_rules_alert_v2`)
   on the workspace-based Application Insights, counting failed `AppRequests` per function; the
   CI principal's Contributor on `rg-energy-dev` covers alert rules and action groups.
6. **Job failure email without publishing the address:** the repo is public and `alert_email` is a
   sensitive Terraform variable. Confirm a bundle variable (`BUNDLE_VAR_alert_email` from the repo
   variable in CI) keeps it out of the repository while the job settings hold it.
   **Checked 2026-10-23** (PR A): a bundle variable without a default, set from
   `BUNDLE_VAR_alert_email` (the `ALERT_EMAIL` repository variable) in `databricks.yml`'s workflow.
   `bundle validate` resolves it into the jobs' `email_notifications`, and fails with "no value
   assigned to required variable alert_email" when it's missing, so it can't silently be empty.

## Deliverables

Delivered as small PRs in this order: (A) alerts, (B) report models and the report dashboard,
(C) pipeline health (system tables, dbt results, health dashboard), (D) README and docs. A first,
because "failures alert" is half of the done-when and needs nothing else.

### A. Alerts

Databricks jobs (`databricks/resources/*.yml`):

- `email_notifications.on_failure` to the owner on `bronze_load`, `dbt_build` and `bronze_rebuild`,
  after retries (a run that succeeds on its retry doesn't email). `dbt_build` failing covers stale
  sources too: its last command is `dbt source freshness`, which errors after 24 hours.
- A duration threshold (`health` rule `RUN_DURATION_SECONDS`) on both scheduled jobs, so a run
  stuck for an hour warns instead of billing quietly: 30 minutes for `bronze_load` (normally ~7),
  30 for `dbt_build` (normally ~6).
- The address is a bundle variable set from the `ALERT_EMAIL` repository variable in CI (step 0
  item 6); never in the repository.

Azure (Terraform, new module `infra/modules/monitoring/`):

- An action group `ag-energy-dev` that emails `alert_email`.
- A log alert per ingestion function on Application Insights: **two or more failed runs in three
  hours** fires (decision 4), evaluated hourly, auto-resolving. One failure (a source's brief
  outage, which the 48-hour window covers anyway) stays quiet; a source down for hours doesn't.
- The budget's existing alerts stay as they are.

CI: failed `main` deploys already email the pusher (GitHub's default); documented, nothing to add.

### B. Report models and the report dashboard

dbt report models in `models/reports/` (gold, contracts enforced, tested), one per page, built from
the facts and dimensions (decision 1). They turn the `analyses/` queries into tested models:

| Model | Grain | For |
| --- | --- | --- |
| `rpt_wind_price` | year × price grain, plus a binned scatter (wind band × price band) | Q1 |
| `rpt_negative_prices` | price band, plus by local hour and by month | Q2 |
| `rpt_winter_consumption_temperature` | temperature band | Q3 |
| `rpt_price_profiles` | day type × local hour; intra-hour spread by price grain | Q4 |
| `rpt_price_spikes` | the top 1 % and the negative intervals, with wind, consumption, temperature, hour and weekday against all intervals | price-spike anatomy |

- An **exposure** (`models/reports/_exposures.yml`) for the dashboard, so dbt's lineage shows which
  models it depends on and slim CI knows what a model change touches.
- The analyses stay as they are (ad hoc), or are removed where a report model replaces them.
  **Done (PR B1):** nine models instead of five, since a page often needs a model for its numbers
  and one for its chart (e.g. `rpt_wind_price_fit` and `rpt_wind_price_bands`); every analysis was
  replaced, so `dbt/analyses/` is gone.

The dashboard `energy_report` (AI/BI, `databricks/resources/dashboards/energy_report.lv.json`):

- Pages: overview (headline numbers and the one-line findings), the four questions, price spikes.
- Each dataset is a `select` from one report model, no logic in the dashboard (decision 1).
- Deployed by the bundle, published with embedded credentials (step 0 item 3), the owner can view.
  Local time throughout (the report layer is where UTC becomes `Europe/Helsinki`).
- **Editing:** the repository's `.lv.json` is the source of truth. Layout changes are made in the
  UI and pulled into the file with `databricks bundle generate dashboard --resource energy_report`
  (`--watch` while editing), then go through a PR; small text or query changes can be made in the
  file directly; numbers and logic change in the `rpt_*` models.
- **Drift warning** (owner's request, 2026-10-24): if the deployed dashboard was edited in the UI
  and the change never made it into the repository, CI says so instead of silently overwriting it
  or failing obscurely:
  - on every PR that runs the Databricks checks, a warning annotation and job summary (instead of
    a PR comment, which would need write rights on PRs) when the deployed dashboard's definition
    differs from the file on the base branch. The read-only principal fetches it (view rights on
    the dashboards). Not `bundle plan`, which reads the bundle state, and not bundle-wide
    permissions: both need rights on the deployment folder the read-only principal mustn't have
    (`bundle validate` asks for CAN_MANAGE on it once top-level permissions exist; found on this
    PR's first run);
  - on `main`, the deploy stops with the same explanation rather than overwriting, unless the
    commit itself updated the dashboard file (then the repository wins, as intended);
  - the owner gets view rights only on the deployed dashboard, so editing means cloning it to a
    draft first. That alone isn't airtight (workspace admins can edit any dashboard), which is
    why the check exists. The mechanism follows step 0 item 2.

### C. Pipeline health

- **System tables:** `bootstrap.sh` grants `USE SCHEMA`/`SELECT` on `system.billing` and
  `system.lakeflow` to both service principals (step 0 item 1); the owner has them as account admin.
- **ops models** (changed during implementation, following decision 1): the health dashboard
  doesn't query the system tables itself. dbt views in `ops` do the work, `ops_job_runs`,
  `ops_daily_cost`, `ops_data_freshness`, `ops_dbt_runs`, `ops_dbt_issues`, recorded as the
  `pipeline_health` exposure. Views rather than tables, so the dashboard shows the state when it's
  opened, not at the last dbt run.
- **dbt results:** an `on-run-end` hook writes each run's node results (model/test, status,
  duration, failures, invocation id, run time) to `energy.ops.dbt_results` (decision 2). New schema
  `ops` in Terraform, owned by the CI principal like the others. Only the `prod` target writes;
  dev and PR runs skip the hook.
- The dashboard `pipeline_health`:
  - job runs from `system.lakeflow.job_run_timeline`: success rate and duration per job, last 30
    days;
  - dbt: latest run's test results, failures over time (from `ops.dbt_results`);
  - freshness: newest `_ingested_at` per bronze table and newest interval in gold;
  - cost: daily DBUs and list-price cost by product from `system.billing.usage` and
    `system.billing.list_prices` (which also answers phase 2 and 3's open cost items).

### D. README and docs

- README: the report section with a screenshot per page and a one-line finding per question; the
  pipeline-health page; how alerts reach the owner.
- `docs/architecture.md` (monitoring, dashboards), `docs/data-model.md` (report models, `ops`),
  `dbt/README.md`, `databricks/README.md` (editing a dashboard: UI draft, export, PR).
- ADR if a decision below turns out to be lasting enough (e.g. report models in dbt).

## Cost estimate

Dashboards query the warehouse when viewed (results are cached), a few seconds of 2X-Small time per
visit. The report models add seconds to the daily dbt run. Alert rules: Azure Monitor log alerts
are billed per monitored time series and month by evaluation frequency; the Azure Retail Prices
API (2026-10-23) lists $0.50/month at 15-minute frequency and nothing cheaper, so one rule split
by function (three time series) is about $1.50/month. Action group emails are free (up to 1,000 a
month). Databricks job notifications are free. Worth checking
against the budget once phase 2 and 3's week-1 costs are in (from 2026-10-29).

## Decisions (made by the owner on 2026-10-23)

1. **The report logic lives in dbt report models** (`rpt_*` in gold, contracts, tests, an
   exposure), and the dashboard only selects from them, so the numbers in the README come from
   tested code. Rejected: SQL in the dashboard's datasets (quicker to iterate, but untested,
   unlinted and invisible to dbt's lineage and slim CI).
2. **dbt results come from an `on-run-end` hook** into `ops.dbt_results`: a small macro, no new
   package. Rejected: the `elementary` package (a large dependency with its own schema and models)
   and job status only.
3. **Alerts are email only** (Azure action group, Databricks job notifications), so no secret is
   needed. Rejected: a Teams or Slack webhook (a secret to store and rotate).
4. **A function alert fires on two or more failures in three hours.** A single failure, which the
   48-hour window refetches anyway, stays quiet. Rejected: an email for every failure (one per
   hour during an outage like ENTSO-E's).
5. **Two dashboards:** `energy_report` (the findings, for the README) and `pipeline_health`
   (operations, cost). Different readers, and the report one needs no access to system tables.

## Acceptance criteria

- [ ] Step 0 items are resolved and recorded here.
- [ ] A deliberately failed job run emails the owner (e.g. `bronze_rebuild` with an unknown source),
      and so does a function alert (fired by a test query or by lowering the threshold once).
- [ ] No email address or other personal data in the repository (gitleaks clean; the bundle and
      Terraform read it from variables).
- [ ] `dbt build` passes with the report models (contracts, tests); slim CI builds a changed report
      model in its PR schema.
- [ ] Both dashboards are deployed by CI, published, and show current data; each report page
      answers its question (screenshots in the README).
- [ ] The health dashboard shows job runs, dbt results, freshness and cost; the cost figures are
      used to record phase 2 and 3's week-1 cost.
- [ ] `terraform plan` after apply shows no changes.

## Interview notes to capture (in README or ADRs)

- Why the report logic is in dbt models with an exposure, not in the dashboard.
- Why alert on two failures in three hours, and why freshness alerts come from the dbt job.
- How a published dashboard's embedded credentials work and why the CI principal publishes.
- What the system tables give for free (job runs, billing) and why their grants are in bootstrap.
