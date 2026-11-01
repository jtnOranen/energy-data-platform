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
   landing, re-run `bootstrap.sh`. Claude Code prepares each step and checks the results.
2. If the orphaned catalog exists: delete it as metastore admin (step 0 item 6).
3. Retake the README screenshots of the wind and negative-price pages, which predate PR #56
   (optional).

## Step 0: verify

1. **Stable names:** a `removed` block (Terraform 1.7+, we pin `~> 1.9`) with `destroy = false`
   takes `random_string.suffix` out of the state without destroying anything, and a `suffix`
   variable with today's value replaces it. Confirm the plan shows no changes to the named
   resources, and that Azure lets a storage account and function app take the same name again
   right after deletion.
2. **Key Vault recovery:** with `purge_soft_delete_on_destroy = false` and
   `recover_soft_deleted_key_vaults = true` (the default), does the apply recover the soft-deleted
   vault with its secrets, and do the role assignments (owner, function app) come back with it?
   The same for the Log Analytics workspace (soft-deleted for 14 days, recovered on re-create
   with the same name).
3. **Warehouse ID without hardcoding:** a bundle variable with `lookup: warehouse: <name>` for the
   dashboards; the CLI (`databricks warehouses list`) in the PR cleanup workflow; and for dbt, can
   the job pass `DBT_DATABRICKS_HTTP_PATH` to the serverless dbt task (task environment variables),
   or does `profiles.yml` look the warehouse up some other way? Local development may keep a
   fallback, but the job and CI must not depend on it.
4. **Catalog destroy:** `force_destroy` on `databricks_catalog` (and the schemas) behind a variable
   that defaults to `false`, set to `true` only by the destroy workflow, which applies it before it
   destroys. Confirm that a normal plan never shows it, and what else blocks the destroy (the
   checkpoint volume, external locations still used by tables, grants).
5. **Order and identities:** `databricks bundle destroy` before `terraform destroy` (the jobs use
   the catalog), both as the deploying principal in the `dev` environment. Which parts of the
   destroy does it lack rights for? It is Contributor on `rg-energy-dev` only, and `bootstrap.sh`
   made the role assignments it can't make itself.
6. **Orphaned catalog:** list the metastore's catalogs and remove the hybrid workspace's default
   catalog if it is still there.
7. **Disabling personal access tokens:** `databricks_workspace_conf` with
   `enableTokensConfig = false` from Terraform (the CI principal is a workspace admin). Nothing uses
   a PAT (phase 2's acceptance criteria), but check the dbt task's injected `DBT_ACCESS_TOKEN` and
   the owner's local `az` tokens still work afterwards.
8. **dbt docs on GitHub Pages:** what the generated `catalog.json` contains (column statistics from
   the warehouse) before publishing it from a public repository, and whether `actions/deploy-pages`
   needs anything beyond `pages: write` and `id-token: write` on the deploy job.

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

## Decisions (to be made by the owner)

1. **What the rebuild destroys.** *Recommended:* everything Terraform and the bundle own; the
   workspace and the other `bootstrap.sh` objects stay, and `bootstrap.sh` is re-run to show it is
   idempotent. *Alternative:* also delete the workspace, so `bootstrap.sh` recreates it; a fuller
   test, but the workspace URL and ID change (repository variables, `databricks.yml`,
   `dbt_project.yml`), and that is the kind of change ADR 0013 already went through once.
2. **Where landing comes from after the rebuild.** *Recommended:* back it up before the destroy
   and restore it after (649 MB with `az storage blob download-batch` / `upload-batch` as the
   owner), so the rebuilt gold can be compared exactly with the old. *Alternative:* re-run the
   phase 1 backfill from the APIs; shows the whole chain from the sources, but takes hours within
   the rate limits, and revised data makes the comparison inexact.
3. **Where the interview notes go.** *Recommended:* `docs/design-notes.md`, short answers grouped
   by topic, each linking its ADR, and linked from the README; the README stays a summary.
   *Alternative:* sections in the README itself (one place to read, but it doubles in length).
4. **The dbt docs site.** *Recommended:* publish it to GitHub Pages from `main` when `dbt/`
   changes, linked from the README. *Alternative:* keep it as a CI artifact only and drop the
   backlog item.

## Acceptance criteria

- [ ] Step 0 items are resolved and recorded here.
- [ ] Plans after PRs A and D show no changes beyond what each PR intends; the post-apply check
      passes.
- [ ] The repository holds no ID that a rebuild changes (warehouse ID, storage account name), and
      no secret.
- [ ] The rebuild test ran through CI (no local `apply` or `destroy`): everything Terraform and the
      bundle own was destroyed and rebuilt, and the steps are in `docs/rebuild.md`.
- [ ] After the rebuild, bronze has the same files and rows as the baseline, and gold's row counts
      and per-day sums match it up to the cutoff; the scheduled jobs and the function then run on
      their own, with no gap in the data.
- [ ] Both dashboards render with current data; a deliberately failed job still emails the owner.
- [ ] The rebuild's time, cost and every manual step are recorded here.
- [ ] Personal access tokens are off; the dbt docs site is published (if decision 4 keeps it); the
      orphaned catalog is gone or confirmed absent.
- [ ] The README has the cost report and the limitations; the interview notes of phases 0–6 are
      written up (decision 3).

## Interview notes to capture (in README or ADRs)

- What "rebuildable" means here: what Terraform owns, what `bootstrap.sh` owns and why, and what
  is restored rather than recreated (landing, API keys).
- Why pin resource names instead of letting a rebuild generate new ones.
- Why the destroy runs in CI behind a typed confirmation, and why `force_destroy` is off except
  during that run.
- What the platform costs to run and to rebuild, and the change that cut it by two thirds.
