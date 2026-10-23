# Phase 4 — CI/CD

## Goal

Every pull request runs the checks for the parts it touches, `main` accepts nothing without them
being green, and a push to `main` deploys every part in a fixed order. Pull requests run with an
identity that can read the platform but not change it, and dbt changes are built and tested in a
schema of their own before they merge.

Done when (from `docs/roadmap.md`): **nothing reaches `main` without green checks.**

## Where we start (checked 2026-10-23)

Phases 1–3 already pulled most per-part CI forward. What exists:

| Workflow | On PRs | On `main` |
| --- | --- | --- |
| `terraform.yml` (`infra/**`) | fmt, validate, plan, plan as PR comment | plan, then apply in `dev` |
| `ingestion.yml` (`ingestion/**`) | ruff, pytest | the same, then deploy the function |
| `databricks.yml` (`databricks/**`, `dbt/**`) | ruff, pytest with Spark, bundle validate | the same, then bundle deploy |
| `dbt.yml` (`dbt/**`) | dbt parse, sqlfluff, docs artifact | the same |

The gaps:

1. **No required status checks.** `main` requires a pull request, but its branch protection has
   `required_status_checks: null`: a red PR can be merged. The phase's goal isn't met today.
2. **Path filters and required checks don't mix.** A workflow skipped by its `paths` filter
   reports nothing, so a check required by name waits forever on PRs that don't touch that part.
   Making the current checks required as they are would block every docs-only PR.
3. **The pre-commit hooks run only locally.** gitleaks, terraform fmt/validate and ruff are in
   `.pre-commit-config.yaml`, but a commit made without the hooks installed reaches the PR
   unchecked. For a public repository, secret scanning should not depend on a local setup.
4. **PRs use the deploying identity.** The `pull_request` federated credential belongs to the same
   service principal as `main` (Contributor on `rg-energy-dev`, owner of the Unity Catalog
   objects), so a workflow edited on a branch could change infrastructure (roadmap backlog).
5. **Third-party actions are pinned to tags**, which a compromised release can move (backlog).
6. **The `dev` environment has no protection rules** (backlog): any branch's workflow could deploy.
7. **dbt changes aren't built before merging** (phase 3, decision 3): parse and lint only, so a
   wrong model or failing test is found by the 07:15 production run.
8. **Deploys on `main` run in parallel and unordered.** A PR touching `infra/` and `databricks/`
   starts the apply and the bundle deploy at the same time, although the bundle depends on what
   Terraform creates. And PR plans collide with `main`'s apply on the state lock (a known gotcha).

## Out of scope

Alerting on failed runs and the pipeline-health page (phase 5). A second environment (one `dev`,
`docs/architecture.md`). Publishing the dbt docs site (phase 6). Changing what the checks check:
this phase is about running them reliably and safely, not adding new kinds of tests.

## Manual prerequisites (owner)

1. Re-run `infra/bootstrap/bootstrap.sh` after PR A's change, before merging it: it creates the
   read-only service principal and moves the `pull_request` federated credential to it.
2. Apply the branch protection and environment settings (the script in PR A does it with `gh`;
   the owner runs it, since repository settings need the owner's GitHub rights).

## Step 0: verify

Checked before or in the PR that needs them; outcomes recorded here.

1. **What a read-only identity can plan.** `terraform plan` refreshes every resource. With
   `Reader` on `rg-energy-dev` plus data roles, does it get through the azurerm resources
   (storage containers through Entra ID, since Shared Key is off; Key Vault; the function app),
   and through the `databricks` provider's Unity Catalog objects? The owner's local plan already
   showed that reading the storage credential needs more than catalog-level privileges. Find the
   least set of Unity Catalog privileges (or a metastore-level role) that lets a non-owner refresh
   the storage credential, external locations, catalog, schemas, volume, grants and the warehouse,
   or decide to plan the Databricks modules only on `main` (fallback, see decision 2).
   **Checked 2026-10-23** (PR #30's plan as the PR principal, with the grants from PR #29): every
   azurerm resource and every Databricks object refreshed with read rights, except two:
   `databricks_permissions` on the warehouse ("does not have Manage permissions": reading a
   warehouse ACL needs `CAN_MANAGE`, which would also allow changing it) and the storage credential
   ("does not have any privileges on Credential"). Rather than grant either, **PR plans run with
   `-refresh=false`**: they compare the configuration with the state without reading any
   resource, so they cover all modules with read rights only. They don't show drift (changes made
   outside Terraform); `main` refreshes before every apply and checks for an empty plan after it,
   so drift is still caught. This replaces the fallback in decision 2 (Azure modules only), which
   would have left the Databricks modules unplanned on PRs.
2. **State lock with read-only access:** plans on PRs use `-lock=false` (a read-only identity
   can't take the blob lease). Confirm the azurerm backend reads state with only
   `Storage Blob Data Reader`, and that this also ends the PR-plan vs `main`-apply lock collisions.
   **Confirmed 2026-10-23:** `terraform init` and the lockless plan work with `Storage Blob Data
   Reader` on the state account. A PR plan no longer takes the lock, so it can't collide with an
   apply on `main`.
3. **Required check from a reusable-workflow setup:** the name GitHub reports for the gate job
   (e.g. `CI / all checks passed`), and that a gate depending on skipped jobs still reports
   success. **Confirmed 2026-10-23** (PR #32): the check is reported as the job name,
   `all checks passed`; branch protection requires that context, bound to the GitHub Actions app
   (ID 15368). With `if: always()` it reports success when the jobs it needs were skipped.
4. **Downloading the production dbt manifest** from the latest successful `main` run of the CI
   workflow (`actions/download-artifact` with `run-id` and `github-token`, or `gh run download`),
   and that `dbt build --select state:modified+ --defer --state <dir>` resolves unmodified models
   to `energy.silver`/`energy.gold`. **Confirmed 2026-10-23:** the artifacts API (newest
   unexpired `dbt-prod-manifest` from `main`) plus `gh run download`, with `actions: read`. PR #36
   (no model changes) found the manifest and built nothing; PR #39 (a comment in `dim_date`) built
   `dim_date` and the two facts (their contracts' foreign keys reference it) with their tests, 16
   nodes of 85, reading everything else from production.
5. **Dependabot** supports both ecosystems we need: `github-actions` (keeps SHA pins current) and
   `uv` (`uv.lock`). **Confirmed 2026-10-23:** its first run opened one grouped PR for each (#37,
   #38).

## Deliverables

Delivered as small PRs in this order: (A) read-only PR identity and repository settings,
(B) one CI workflow with a single required gate, (C) dbt PR schemas (slim CI), (D) supply-chain
hardening (SHA pins, Dependabot), (E) docs.

A is split in two so nothing breaks in between (changed during implementation). **A1** creates the
PR principal (bootstrap: both app registrations hold the `pull_request` credential for now) and
grants it read access in Terraform, while PR workflows still use the deploying principal, so A1's
own plan runs as before. **A2** switches the PR jobs to the PR principal, which makes A2's own CI
the step 0 item 1 test, and removes the `pull_request` credential from the deploying app. The
branch protection's required check is added with B, once the gate check exists: requiring a check
that never reports would block every merge, B's included.

### A. Read-only identity for pull requests and repository settings

`infra/bootstrap/bootstrap.sh`:

- A second app registration and service principal **`gh-energy-data-platform-pr`**. The
  `pull_request` federated credential moves to it; the deploying principal keeps only the `main`
  and `environment:dev` credentials.
- Its Azure roles: `Reader` on `rg-energy-dev`, `Storage Blob Data Reader` on the state container
  and on `landing`/`lake` (plan refreshes container properties through Entra ID), `Key Vault
  Reader` (metadata only, no secret values).
- Added to the Databricks workspace as a regular user (not an admin) through SCIM, like the
  deploying principal.
- New repository variable `AZURE_PR_CLIENT_ID`; PR jobs use it, `main` jobs keep
  `AZURE_CLIENT_ID`.

Terraform (`modules/unity_catalog`, `modules/sql_warehouse`), for the PR principal:

- `USE_CATALOG`, `USE_SCHEMA`, `SELECT` on `energy` (read bronze, silver and gold, for plans and
  for dbt deferral) and `CREATE_SCHEMA` on the catalog (its own `pr_<n>_*` schemas, decision 3).
- Whatever step 0 item 1 shows is needed to refresh the storage credential and external
  locations, if it can be granted without write rights.
- `CAN_USE` on the warehouse.

Repository settings, applied by a script the owner runs (`infra/bootstrap/github-settings.sh`,
idempotent, `gh api`; not Terraform, which would need a GitHub token as a secret):

- Branch protection on `main`: the gate check from B is **required**, branches must be up to date
  before merging, `enforce_admins` stays on (the owner can't bypass it either), no force pushes.
- Squash merge only, delete branches after merge.
- Environment `dev`: deployments only from `main` (deployment branch policy), no required
  reviewer (decision 4).

### B. One CI workflow with a single required gate

`.github/workflows/ci.yml` replaces the four entry points; the per-part workflows become
**reusable workflows** (`on: workflow_call`) with their jobs unchanged:

```
ci.yml
├── changes        which parts changed (paths filter on the PR's diff; on main: the pushed commit)
├── precommit      always: pre-commit run --all-files (gitleaks, fmt, ruff, ...)
├── terraform      if infra changed      → terraform.yml   (PR: plan -lock=false as the PR SP)
├── ingestion      if ingestion changed  → ingestion.yml
├── databricks     if databricks or dbt changed → databricks.yml
├── dbt            if dbt changed        → dbt.yml          (PR: slim CI, part C)
└── all checks passed   always; fails if any needed job failed or was cancelled
```

- **The gate is the only required check.** It runs on every PR (`if: always()`), so docs-only PRs
  are mergeable, and it fails if any job it depends on failed; skipped jobs count as passed.
- On `main`, deploys run **in order**: Terraform apply, then the function deploy, then the bundle
  deploy, each only if its part changed (or, for the bundle, if Terraform changed something it
  depends on). Each deploy keeps its own `concurrency` group (changed during implementation, from
  one group for all): GitHub keeps only the newest pending run of a group, and dropping a pending
  deploy is safe only when a newer deploy of the *same* part replaces it, since every deploy is
  the full state of its part at that commit. A workflow-level group on `main` could drop a whole
  run whose changes the next run doesn't touch.
- PR jobs authenticate as the read-only principal (A); `main` jobs as the deploying one. The
  fork-PR gate (`IS_TRUSTED_SOURCE`) stays: fork PRs get the checks that need no Azure.
- `precommit` runs the same hooks as local commits (one source of truth), with gitleaks over the
  PR's commits, so a secret committed without hooks still fails the PR.

### C. dbt in pull-request schemas (slim CI)

In `dbt.yml`, for PRs from this repository:

- Download the production manifest: on `main`, the CI uploads `dbt parse --target prod`'s
  `manifest.json` as an artifact; PRs fetch it from the latest successful `main` run (step 0
  item 4).
- `dbt build --target pr --select state:modified+ --defer --state prod-manifest/`, as the PR
  principal, into **`pr_<number>_silver` / `pr_<number>_gold`** (the schema macro already
  prefixes every non-prod target). Unmodified upstream models are read from production (`--defer`),
  so a PR builds only what it changed and what depends on it, and its unit tests and data tests run
  against real data.
- New target `pr` in `profiles.yml`: token from OIDC like `ci`, `schema` from the PR number.
- A small data window (decision 3): `--vars` limits the facts to the last 30 days, so a PR that
  touches `fct_power_15min` doesn't rebuild 2024 onwards.
- **Cleanup:** a workflow on `pull_request: closed` drops `pr_<number>_silver` and
  `pr_<number>_gold` (`DROP SCHEMA … CASCADE`) as the PR principal, which owns them.

### D. Supply-chain hardening

- Every third-party action pinned to a full commit SHA, with the version in a comment
  (`uses: actions/checkout@<sha> # v4.2.2`).
- `.github/dependabot.yml`: `github-actions` and `uv`, weekly, grouped into one PR per ecosystem,
  so the pins stay current without a stream of PRs.
- Workflow-level `permissions: contents: read`, widened per job only where needed (already the
  pattern; checked for every job).

### E. Docs

- ADR 0015 (written with this spec): one CI entry point with a single required gate check (why not required checks per
  workflow, why not run everything on every PR).
- ADR 0016 (written with this spec): a read-only identity for pull requests (what it can and can't do, and the plan
  limitations it brings).
- `docs/architecture.md` (security model, environments), `CLAUDE.md` (the local-plan note, the
  state-lock gotcha that `-lock=false` retires), `docs/roadmap.md` backlog (phase 4 items done),
  README badge for the CI workflow.

## Decisions (made by the owner on 2026-10-23)

1. **One `ci.yml` with reusable workflows and a gate job** that is the only required check:
   change detection decides what runs, and the gate always reports, so docs-only PRs stay
   mergeable. Rejected: dropping the path filters and requiring every workflow (every PR, even
   docs-only, would run Spark tests, a Terraform plan and Azure logins), and requiring nothing
   (today's state, which fails the phase's goal). It also gives `main` an ordered deploy. See
   ADR 0015.
2. **A read-only identity for PRs now**, in PR A, with step 0 item 1 deciding the exact grants. If
   the Databricks objects can't be refreshed without write rights, PR plans target the Azure
   modules only and the full plan runs on `main` before the apply (which already happens). It
   closes the one real hole in the security model. See ADR 0016.
3. **dbt PR builds use the last 30 days** for the incremental facts (`--vars`), everything else as
   is, so a PR build takes seconds of warehouse time. The full rebuild still happens in
   production, and the singular tests work on any window of whole days.
4. **The `dev` environment accepts deployments from `main` only**, with no required reviewer: with
   one owner, a reviewer rule would only make the owner approve their own deployment after the PR
   was already reviewed.

## Acceptance criteria

Checked 2026-10-23 (PRs #29–#41). Probe PRs (#33, #34, #40) were closed without merging.

- [x] Step 0 items are resolved and recorded here.
- [x] A PR with a deliberately failing check **cannot be merged**: #33 added a failing pytest test;
      the gate failed and `gh pr merge` was refused ("the base branch policy prohibits the merge",
      `mergeStateStatus: BLOCKED`), admins included (`enforce_admins`). A docs-only PR can: this
      one (#41) skipped every part's checks and the gate passed. (A lint error was not used for
      the probe: the local pre-commit hooks stop it before it can be committed.)
- [x] A PR commit containing a fake secret is caught by gitleaks in CI: #34 committed a random
      API key with `--no-verify` (owner's request, to bypass the local hook that had blocked it);
      CI's gitleaks job reported `generic-api-key` (secret redacted in the log) and the merge was
      blocked.
- [x] PR jobs run as `gh-energy-data-platform-pr`, and it can't change anything: #40 logged in as it
      and tried to tag `rg-energy-dev` (`AuthorizationFailed`), create a container in the ADLS
      account (HTTP 403; the account has no network rules), create tables in `silver` and `gold`,
      insert into `bronze` and drop a `silver` view (all `PERMISSION_DENIED`). It can't deploy
      either: the `dev` environment takes deployments only from `main`, and the deploying app no
      longer has a `pull_request` credential.
- [x] A dbt PR builds only `state:modified+` in `pr_<n>_*` schemas with unit and data tests (#39:
      16 of 85 nodes in `pr_39_gold`), and closing the PR drops those schemas (#35's
      `pr_35_silver`/`pr_35_gold` dropped by `dbt-pr-cleanup.yml` on merge; checked in
      `information_schema`).
- [x] A merge touching `infra/` and `databricks/` applies Terraform before deploying the bundle: every
      `main` run since #32 that changed all parts ran `terraform / apply`, then `ingestion /
      deploy`, then `databricks / bundle deploy`, each waiting for the previous.
- [x] Every third-party action is pinned to a SHA (#36, 31 references; `azure/login` unified on
      v3.1.0); Dependabot opened its first grouped PRs (#37 merged: six actions to new majors, all
      checks and the following `main` deploy green; #38 closed: pyspark stays on 4.1 to match
      serverless environment 6, now ignored in `dependabot.yml`).
- [x] `terraform plan` after apply shows no changes (the apply job's check, on every `main` run).

## Interview notes to capture (in README or ADRs)

- Why a single gate check instead of requiring each workflow, and how path filters break required
  checks.
- What the read-only PR identity can and can't do, and why plans run with `-lock=false`.
- How slim CI with `state:modified+` and `--defer` builds only what changed, against production.
- Why SHA pins (and Dependabot to keep them current) instead of tags.
- Why the repository settings are a `gh` script and not Terraform.
