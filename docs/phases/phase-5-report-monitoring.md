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

1. In the Databricks account console, make the owner a **metastore admin** of
   `metastore_azure_swedencentral` (the owner is account admin as the tenant's Global
   Administrator). Needed once, to grant access to the system tables (step 0 item 1).
2. Build the first draft of each dashboard in the workspace UI with Claude Code's queries, so the
   layout is designed by eye; the bundle then takes over the exported definition (deliverable B).

## Step 0: verify

1. **System tables access:** after prerequisite 1, can the owner grant `USE SCHEMA` and `SELECT` on
   `system.billing` and `system.lakeflow` to the CI service principal (which publishes the
   dashboards and so runs their queries, item 3) and to themselves? Which system schemas need
   enabling first (`lakeflow` may be off by default)? The grants are owner-rights operations, so
   they go into `bootstrap.sh`, not Terraform (the CI principal can't grant on `system`).
2. **Dashboards in the bundle:** the `dashboards` resource (`file_path` to a `.lv.json`,
   `warehouse_id`, `embed_credentials`, permissions) and `databricks bundle generate dashboard
   --existing-id` to export a UI draft, with the CLI version CI pins. What happens on deploy when
   the dashboard was edited in the UI since (the bundle warns about remote changes)?
3. **Whose rights a published dashboard uses:** with embedded credentials, queries run as the
   publisher, here the CI principal; viewers need only view permission. Confirm that, and that the
   owner can view it.
4. **dbt results in a table:** an `on-run-end` hook gets `results` (status, timing, failures per
   node) in dbt 1.12; confirm the fields and that a macro can insert them into a Delta table in the
   same run, on the job's serverless dbt task.
5. **Function failure alert:** an Azure Monitor log alert (`azurerm_monitor_scheduled_query_rules_alert_v2`)
   on the workspace-based Application Insights, counting failed `AppRequests` per function; the
   CI principal's Contributor on `rg-energy-dev` covers alert rules and action groups.
6. **Job failure email without publishing the address:** the repo is public and `alert_email` is a
   sensitive Terraform variable. Confirm a bundle variable (`BUNDLE_VAR_alert_email` from the repo
   variable in CI) keeps it out of the repository while the job settings hold it.

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

The dashboard `energy_report` (AI/BI, `databricks/resources/dashboards/energy_report.lv.json`):

- Pages: overview (headline numbers and the one-line findings), the four questions, price spikes.
- Each dataset is a `select` from one report model, no logic in the dashboard (decision 1).
- Deployed by the bundle, published with embedded credentials (step 0 item 3), the owner can view.
  Local time throughout (the report layer is where UTC becomes `Europe/Helsinki`).

### C. Pipeline health

- **System tables:** `bootstrap.sh` grants `USE SCHEMA`/`SELECT` on `system.billing` and
  `system.lakeflow` to the CI principal and the owner (step 0 item 1).
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
are billed per rule and month, by evaluation frequency; roughly a dollar or two per rule at
hourly evaluation, so a few dollars a month for three (to confirm on the Azure pricing page with
step 0 item 5, before PR A); action group emails are free. Databricks job notifications are free. Worth checking
against the budget once phase 2 and 3's week-1 costs are in (from 2026-10-29).

## Decisions (open, for the owner)

1. **Where the report logic lives.** (a) **dbt report models** (`rpt_*` in gold, contracts, tests,
   an exposure), and the dashboard only selects from them. (b) SQL in the dashboard's datasets:
   quicker to iterate, but untested, unlinted and invisible to dbt's lineage and slim CI.
   **Recommendation: (a)**: the numbers in the README then come from tested code.
2. **dbt results for the health page.** (a) **An `on-run-end` hook** into `ops.dbt_results`: a small
   macro, no new package. (b) The `elementary` package: richer, but a large dependency with its
   own schema and models. (c) No dbt results, job status only from system tables. **Recommendation:
   (a)**.
3. **Alert channel.** (a) **Email only** (Azure action group, Databricks job notifications), no
   secrets. (b) Also a Teams or Slack webhook: a secret to store and rotate. **Recommendation: (a)**.
4. **Function alert threshold.** (a) **Two or more failures in three hours** per function. (b)
   Every failure: one email per hour during an outage like ENTSO-E's, mostly noise since the 48-hour
   window refetches. **Recommendation: (a)**.
5. **One dashboard or two.** (a) **Two**: `energy_report` (the findings, for the README) and
   `pipeline_health` (operations, cost). Different readers, and the report one needs no access to
   system tables. (b) One dashboard with a health page. **Recommendation: (a)**.

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
