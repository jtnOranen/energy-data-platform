# Phase 6 — Polish

## Goal

Prove that the platform can be rebuilt from the repository: destroy everything Terraform and the
Asset Bundle own, rebuild it through CI, and get the same gold tables back. Then finish what a
reader of the repository needs: the cost report, the limitations, the design notes behind every
decision, and the dbt docs site. Close the backlog items found in earlier phases.

Done when (from `docs/roadmap.md`): **`terraform destroy` + `apply` restores everything.**

## Out of scope

The forecast extension (roadmap: later). A second environment. Deleting the Databricks workspace,
the Terraform state backend, the resource groups, the Entra ID apps or the metastore: those are
owner-rights objects that `bootstrap.sh` creates (ADRs 0007, 0012), and the test re-runs
`bootstrap.sh` to show it is idempotent, not that it can recreate them. Re-fetching history from
the source APIs instead of restoring landing (decision 2).

## Where we start (checked 2026-11-01)

Phases 0–5 are accepted. Everything runs on schedule at about 0.31 EUR a day. A rebuild would break
on these today:

- **Names change.** `random_string.suffix` (in `infra/envs/dev/main.tf`) is in the state, so a
  destroy and apply gives the storage account, Key Vault and function app new names. The bundle's
  `landing_url` default (`databricks/databricks.yml`) names the storage account.
- **The SQL warehouse gets a new ID**, and its current ID `f5e7a914313e58c9` is written in
  `databricks/databricks.yml` (dashboards), `dbt/profiles.yml` (all four targets, the dbt job
  included) and `.github/workflows/dbt-pr-cleanup.yml`.
- **The catalog can't be destroyed** while it has tables: `databricks_catalog` has no
  `force_destroy`, and dbt and the bundle create tables Terraform doesn't know about.
- **The API keys would be purged.** The Key Vault has purge protection off and the azurerm
  provider's default `purge_soft_delete_on_destroy = true`, so a destroy purges the vault and the
  two keys the owner entered by hand (`fingrid-api-key`, `entsoe-token`).
- **Landing is the only copy of the history**: 2,980 files, 649 MB, in the Terraform-owned storage
  account. Phase 1's backfill took hours within the APIs' rate limits.
- **Nothing in CI can destroy or deploy everything at once.** `CLAUDE.md` rule 4 forbids a local
  `terraform apply` or `destroy`, and `ci.yml` deploys only the parts a push changed.

Unaffected: the workspace URL and ID (the workspace stays), the CI principals' IDs, the job and
dashboard IDs (nothing refers to them; the drift check reads them from the bundle state).

Not rebuild-related, from the backlog: the workspace still allows personal access tokens
(`enableTokensConfig`), an orphaned catalog from the deleted hybrid workspace may remain (ADR
0013), the dbt docs site is only a CI artifact, and the README's "Cost" and "Limitations and next
steps" sections are placeholders. Every phase spec ends with "interview notes to capture"; most
are still uncaptured.

## Manual prerequisites (owner)

1. Run the rebuild (deliverable C): trigger the destroy and deploy workflows, back up and restore
   landing, re-run `bootstrap.sh`, purge the soft-deleted Key Vault and enter the two API keys
   again (keep a copy of them outside Azure first; step 0 item 2). Claude Code prepares each step
   and checks the results.
2. If the orphaned catalog exists: delete it as metastore admin (step 0 item 6).
3. Retake the README screenshots of the wind and negative-price pages, which predate PR #56
   (optional).

## Step 0: verify

1. **Stable names:** a `removed` block (Terraform 1.7+, we pin `~> 1.9`) with `destroy = false`
   takes `random_string.suffix` out of the state without destroying anything, and a `suffix`
   variable with today's value replaces it. Confirm the plan shows no changes to the named
   resources, and that Azure lets a storage account and function app take the same name again
   right after deletion.
   **Checked 2026-11-01** (PR A, Terraform 1.14.8): the plan only forgets `random_string.suffix`
   ("will no longer be managed by Terraform, but will not be destroyed"); every name stays. Name
   reuse after deletion is confirmed by the rebuild itself.
2. **Key Vault recovery:** with `purge_soft_delete_on_destroy = false` and
   `recover_soft_deleted_key_vaults = true` (the default), does the apply recover the soft-deleted
   vault with its secrets, and do the role assignments (owner, function app) come back with it?
   The same for the Log Analytics workspace (soft-deleted for 14 days, recovered on re-create
   with the same name).
   **Decided in PR A (2026-11-01): no automatic recovery.** A soft-deleted vault is a
   subscription-level object (`/subscriptions/…/providers/Microsoft.KeyVault/locations/<region>/
   deletedVaults/<name>`), outside the CI principal's Contributor on `rg-energy-dev`, so neither a
   recovery nor a purge by CI can be relied on, and recovering would leave a vault outside the
   state that the apply then can't create. So the provider neither purges on destroy nor recovers
   on apply; in the rebuild the **owner purges the vault** (`az keyvault purge`) and **enters the
   two API keys again** from where they keep them. Log Analytics keeps its default (soft delete,
   recovered by name, which needs no subscription rights).
3. **Warehouse ID without hardcoding:** a bundle variable with `lookup: warehouse: <name>` for the
   dashboards; the CLI (`databricks warehouses list`) in the PR cleanup workflow; and for dbt, can
   the job pass `DBT_DATABRICKS_HTTP_PATH` to the serverless dbt task (task environment variables),
   or does `profiles.yml` look the warehouse up some other way? Local development may keep a
   fallback, but the job and CI must not depend on it.
   **Checked 2026-11-01** (PR A): the bundle variable's `lookup: warehouse: energy-dev` resolves
   (`bundle validate`) for the dashboards and the dbt job. A serverless dbt task can't set
   environment variables, but dbt renders `var()` in `profiles.yml`, so the job passes
   `--vars '{warehouse_id: ...}'` and the `prod` target builds the HTTP path from it. CI and the PR
   cleanup look the warehouse up by name through the API (`odbc_params.path`, `id`). No fallback
   stays: the other targets read `DBT_DATABRICKS_HTTP_PATH` with an empty default, so `dbt parse`
   still runs without a connection (fork PRs, the production manifest), and the owner sets it
   locally (`dbt/README.md`; `dbt debug` passed that way).
4. **Catalog destroy:** `force_destroy` on `databricks_catalog` (and the schemas) behind a variable
   that defaults to `false`, set to `true` only by the destroy workflow, which applies it before it
   destroys. Confirm that a normal plan never shows it, and what else blocks the destroy (the
   checkpoint volume, external locations still used by tables, grants).
   **Partly checked 2026-11-01** (PR A): `allow_destroy` (default `false`) sets `force_destroy` on
   the catalog and the four schemas, and the plan with the default shows no change. What else
   blocks a destroy shows only in the destroy itself (deliverable C).
   **Checked 2026-11-02** (rebuild test): the `lake` external location blocked it, because Unity
   Catalog keeps dropped managed tables for 7 days (UNDROP) and counts them as dependents even
   after the catalog is gone. `allow_destroy` now sets `force_destroy` on it too (#67). Nothing else
   blocked.
5. **Order and identities:** `databricks bundle destroy` before `terraform destroy` (the jobs use
   the catalog), both as the deploying principal in the `dev` environment. Which parts of the
   destroy does it lack rights for? It is Contributor on `rg-energy-dev` only, and `bootstrap.sh`
   made the role assignments it can't make itself.
   **Checked 2026-11-02** (rebuild test): the deploying principal destroyed and created everything,
   role assignments included (it has Role Based Access Control Administrator on `rg-energy-dev`).
   The only thing outside its reach was the soft-deleted Key Vault, which the owner purged, as
   decided in item 2.
6. **Orphaned catalog:** list the metastore's catalogs and remove the hybrid workspace's default
   catalog if it is still there.
   **Checked 2026-11-02:** the metastore lists `energy`, the current workspace's
   `dbw_energy_dev_7405610438268005`, `samples` and `system`; `catalogs get
   dbw_energy_dev_7405615529952621` answers "does not exist" (not a permission error). Nothing to
   delete.
7. **Disabling personal access tokens:** `databricks_workspace_conf` with
   `enableTokensConfig = false` from Terraform (the CI principal is a workspace admin). Nothing uses
   a PAT (phase 2's acceptance criteria), but check the dbt task's injected `DBT_ACCESS_TOKEN` and
   the owner's local `az` tokens still work afterwards.
   **Done 2026-11-02** (#70): no tokens existed (`token-management list` empty). After the apply
   `enableTokensConfig` is `false`, a manual `dbt_build` run passed (the task's connection isn't a
   PAT), and the owner's `az` token still runs SQL and the CLI.
8. **dbt docs on GitHub Pages:** what the generated `catalog.json` contains (column statistics from
   the warehouse) before publishing it from a public repository, and whether `actions/deploy-pages`
   needs anything beyond `pages: write` and `id-token: write` on the deploy job.
   **Done 2026-11-02** (#71): CI generates the docs with `--empty-catalog`, so `catalog.json` holds
   no statistics; the manifest has no email addresses, hosts, IDs or tokens. The deploy job needs
   only those two permissions (and the caller in `ci.yml` must grant `pages: write`), plus Pages
   turned on with GitHub Actions as the source (`github-settings.sh`). The `github-pages`
   environment deploys from `main` only. Live at https://jtnoranen.github.io/energy-data-platform/.

## Deliverables

Small PRs, in order:

- **A: rebuildable infrastructure.** Pinned `suffix` with a `removed` block; Key Vault and Log
  Analytics kept recoverable (provider `features`); `allow_destroy` variable for the catalog and
  schemas; no warehouse ID in the repository (step 0 item 3). Each with a plan showing no changes.
- **B: rebuild workflows and runbook.** `destroy.yml` (`workflow_dispatch` on `main`, `dev`
  environment, a typed confirmation input, bundle destroy then Terraform destroy);
  `workflow_dispatch` on `ci.yml` with an input that deploys every part in the usual order;
  `docs/rebuild.md` with the steps, the landing backup and restore commands, and the SQL that
  records and compares the baseline (row counts per table, and per-day sums of the gold facts'
  measures up to a cutoff).
- **C: the rebuild test**, run by the owner with Claude Code, results recorded here: baseline,
  backup, destroy, `bootstrap.sh`, deploy, restore, `bronze_load` (empty checkpoints, so it loads
  everything), `dbt_build`, compare, dashboards, alerts, the post-apply plan. Wall-clock time and
  cost recorded. Downtime stays well under the 48-hour overlap window, so the function's first
  fetches after the rebuild fill the gap and no data is lost.
- **D: backlog.** Personal access tokens off (step 0 item 7); dbt docs site on GitHub Pages from
  `main` (decision 4); the orphaned catalog (manual, recorded).
- **E: README and design notes.** "Cost" (monthly cost per component from the Azure invoice, the
  ADR 0017 change, what a rebuild costs), "Limitations and next steps", and the interview notes of
  phases 0–5 written up (decision 3). `docs/architecture.md` and the roadmap updated.

## Cost estimate

The rebuild: the first bronze load took about 35 minutes of serverless jobs compute on 2026-10-22
and a full `dbt build` a few minutes of warehouse time, so about 1–3 EUR in all, plus nothing while
the resources are gone. GitHub Pages is free for public repositories. No new running cost.

## Decisions (made by the owner on 2026-11-01)

1. **The rebuild destroys everything Terraform and the bundle own.** The workspace and the other
   `bootstrap.sh` objects stay, and `bootstrap.sh` is re-run to show it is idempotent. Rejected:
   also deleting the workspace (a fuller test, but the workspace URL and ID change in the
   repository variables, `databricks.yml` and `dbt_project.yml`, which ADR 0013 already went
   through once).
2. **Landing is backed up before the destroy and restored after** (649 MB with
   `az storage blob download-batch` / `upload-batch` as the owner), so the rebuilt gold can be
   compared exactly with the old. Rejected: re-running the phase 1 backfill from the APIs (the
   whole chain from the sources, but hours within the rate limits, and revised data makes the
   comparison inexact).
3. **The interview notes go into `docs/design-notes.md`**: short answers grouped by topic, each
   linking its ADR, linked from the README, which stays a summary. Rejected: sections in the
   README itself (one place to read, but it doubles in length).
4. **The dbt docs site is published to GitHub Pages** from `main` when `dbt/` changes, linked from
   the README. Rejected: keeping it as a CI artifact only.

## Acceptance criteria

- [x] Step 0 items are resolved and recorded here. All eight are checked, decided or done above.
- [x] Plans after PRs A and D show no changes beyond what each PR intends; the post-apply check
      passes. PR A's (#64) plan was 0 to add, 0 to change, 0 to destroy (it only forgot
      `random_string.suffix`); #70's added only `databricks_workspace_conf`. The post-apply plan
      (`-detailed-exitcode`, fails on any change) passed on every `main` run through #72.
- [x] The repository holds no ID that a rebuild changes (warehouse ID, storage account name), and
      no secret. On 2026-11-03 neither warehouse ID appears outside the "Where we start" note
      above; the storage account and Key Vault names hold the pinned suffix, which the rebuild
      kept. Gitleaks runs in pre-commit and CI.
- [x] The rebuild test ran through CI (no local `apply` or `destroy`): everything Terraform and the
      bundle own was destroyed and rebuilt, and the steps are in `docs/rebuild.md`. `destroy.yml`
      and `ci.yml` by hand, 2026-11-02 (table below).
- [x] After the rebuild, bronze has the same files and rows as the baseline, and gold's row counts
      and per-day sums match it up to the cutoff; the scheduled jobs and the function then run on
      their own, with no gap in the data. All nine baseline rows identical (cutoff 2026-10-31). On
      2026-11-03 the scheduled `bronze_load` (06:30–06:38) and `dbt_build` (07:15–07:21) succeeded:
      29 nodes, 96 tests, none failed, all five sources fresh. The function ran every hour from
      2026-11-02 16:05 to 11-03 16:15 with no failure, and gold's test that every complete UTC day
      has 96 quarter-hours passed.
- [x] Both dashboards render with current data; a deliberately failed job still emails the owner.
      Both are published on the new warehouse (2026-11-02 15:27), and the owner checked on
      2026-11-03 that both render with that day's data; the failure email arrived 2026-11-02
      (step 11 below).
- [x] The rebuild's time, cost and every manual step are recorded here (the table and the cost
      under "Rebuild test" below).
- [x] Personal access tokens are off; the dbt docs site is published on GitHub Pages; the orphaned
      catalog is gone or confirmed absent. Step 0 items 6–8 (#70, #71).
- [x] The README has the cost report and the limitations; the interview notes of phases 0–6 are
      written up in `docs/design-notes.md` (#72).

## Rebuild test (deliverable C, 2026-11-02)

Run by the owner with Claude Code, following `docs/rebuild.md`. Times UTC.

| Step | When | Result |
| --- | --- | --- |
| 1. Baseline, cutoff 2026-10-31 00:00 | 14:47 | 9 relations recorded |
| 2. Landing backup | 14:50–15:00 | 3,124 files, 673 MB; the first try failed (below) |
| 3. Destroy (`destroy.yml`) | 14:53–15:09 | done on the third run (#67, #68) |
| 4. Purge the Key Vault (owner) | 15:10 | |
| 5. `bootstrap.sh` | 15:11 | everything found, nothing changed |
| 6. Rebuild (`ci.yml` by hand) | 15:12–15:27 | done on the second run; the post-apply plan: "No changes" |
| 7. API keys (owner, portal) | about 15:25 | |
| 8. Landing restore | 15:28–15:31 | 3,124 files |
| 9. `bronze_load`, `dbt_build` | 15:31–15:42, 15:42–15:51 | success; dbt's first attempt failed (below), the retry passed |
| 10. Compare | 15:52 | **all 9 rows identical** (bronze rows and files, gold rows and sums) |
| 11. Alert probe, function | 15:52–16:15 | failure email received; function runs from 16:05 all succeed |

From the start of the destroy to the data back: one hour, of which about 20 minutes went on the
fixes below. The function missed its 15:05–15:15 runs only; the 48-hour window covers them.

Cost: the rebuild's two hours (14:00–16:00) used about 1.1 USD of Databricks at list price, 0.92
on the SQL warehouse (baseline, `dbt_build`, compare) and 0.14 on jobs (the full bronze load), in
line with the 1–3 EUR estimate. The invoice for 2026-11-02 is 2.64 EUR against about 0.30 on a
quiet day; the rest is the CI builds of PRs D and E that evening.

What broke, and what changed:

1. **The PR cleanup had failed since #64**: a missing space between two `jq --arg`s (#66).
2. **The `lake` external location blocked the destroy** (step 0 item 4), and a re-run of the
   destroy would have run a full apply, creating again everything already destroyed. Now
   `force_destroy` on `lake` and an apply targeted at the resources still in the state (#67).
3. **The bundle destroy failed on a re-run**: its warehouse lookup by name fails once the warehouse
   is gone. A placeholder value skips it (#68).
4. **The landing backup failed**: the hierarchical namespace has an empty blob per directory, which
   `download-batch` writes as a file and then can't create the directory. Only `*.xml` and
   `*.json` are downloaded now (#67, `docs/rebuild.md`).
5. **CI's dbt job ran before the apply had created the warehouse** (parallel with Terraform), so
   its lint failed. It now waits for Terraform (#69).
6. **"Re-run failed jobs" doesn't work for the apply**: it reuses the stale saved plan. The runbook
   says to run the whole workflow again (#69).
7. **The two ops views failed in the first `dbt_build`** of the new catalog: they read
   `ops.dbt_results`, which the on-run-end hook only creates after the run. An on-run-start hook
   now creates it first (#69).

The Log Analytics workspace came back with its history (soft delete, recovered by name), as
decided in step 0 item 2.

## Interview notes to capture (in `docs/design-notes.md`)

- What "rebuildable" means here: what Terraform owns, what `bootstrap.sh` owns and why, and what
  is restored rather than recreated (landing, API keys).
- Why pin resource names instead of letting a rebuild generate new ones.
- Why the destroy runs in CI behind a typed confirmation, and why `force_destroy` is off except
  during that run.
- What the platform costs to run and to rebuild, and the change that cut it by two thirds.
