# 0015 — One CI entry point with a single required gate check

- Status: accepted
- Date: 2026-10-23

## Context

Each part of the platform has its own workflow (`terraform.yml`, `ingestion.yml`, `databricks.yml`,
`dbt.yml`), filtered by `paths` so a PR only runs the checks for what it touches. `main` requires a
pull request but no status checks, so a red PR can be merged, which fails phase 4's goal ("nothing
reaches `main` without green checks").

GitHub's required checks are matched by name. A workflow skipped by its `paths` filter reports no
check at all, so a required check from it waits forever on any PR that doesn't touch that part.

On `main`, the four workflows also deploy independently: a PR touching `infra/` and `databricks/`
starts the Terraform apply and the bundle deploy at the same time, although the bundle depends on
resources Terraform creates.

## Options

1. One workflow `ci.yml`: a job detects which parts changed, the per-part workflows become reusable
   (`workflow_call`) and run only when needed, and a final gate job, the only required check, runs
   always and fails if any needed job failed.
2. Drop the path filters and require every workflow's checks. Simple, but every PR, including
   docs-only ones, runs Spark tests, a Terraform plan and Azure logins: several minutes and
   needless cloud calls.
3. Keep the path filters and require nothing (today).

## Decision

Option 1. The gate job (`if: always()`) depends on every check job; skipped jobs count as passed,
failed or cancelled ones fail it. On `main`, the same workflow deploys in a fixed order: Terraform
apply, function deploy, bundle deploy, in one concurrency group.

## Consequences

- One required check to configure in branch protection, whatever parts are added later; a new part
  only needs a job in `ci.yml` and a `needs` entry on the gate.
- Change detection is now part of the CI and must be right: a missed path means a check that
  doesn't run. The paths live in one place (the `changes` job).
- The per-part workflows keep their jobs, so their history and logs read the same; only their
  trigger changes.
- `main` deploys can't race each other any more.
