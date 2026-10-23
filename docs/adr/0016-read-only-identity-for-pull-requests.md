# 0016 — A read-only identity for pull requests

- Status: accepted
- Date: 2026-10-23

## Context

GitHub Actions authenticates to Azure with OIDC federated credentials (ADR 0004). Since phase 0
one service principal has three: `main`, `pull_request` and `environment:dev`. It holds
`Contributor` and `Role Based Access Control Administrator` on `rg-energy-dev`, writes the
Terraform state and owns the Unity Catalog objects. A workflow edited on a branch runs with the
`pull_request` credential, so it could change infrastructure or data before anyone reviews it.
Only the owner can push to this repository, so the risk is theoretical today, but it is the one
place where the security model relies on who has push access instead of on rights.

## Options

1. A second service principal for pull requests with read rights only: `Reader` on the resource
   group, read on the state and storage, read on the catalog, and write only to its own dbt PR
   schemas. The deploying principal keeps the `main` and `environment:dev` credentials.
2. Keep one principal and rely on branch protection and environment rules. Environment rules
   protect the deploy jobs, but not an ordinary PR job that calls `terraform apply` or the
   Databricks API itself.

## Decision

Option 1: `gh-energy-data-platform-pr`, created by `bootstrap.sh` like the deploying principal.

## Consequences

- PR Terraform plans run with `-lock=false`: a reader can't take the state blob's lease. That also
  ends PR plans failing on the lock while `main` applies. Only `main`'s plan, made with the lock,
  is applied.
- PR plans also run with `-refresh=false`. Two reads need more than read rights: a SQL warehouse's
  permissions (`CAN_MANAGE`, which could also change them) and the storage credential (a privilege
  on it). Without refresh the plan compares configuration with state and reads nothing, so it
  covers every module with read rights only. It doesn't show drift; `main` refreshes before every
  apply and checks for an empty plan afterwards (phase 4 spec, step 0 item 1).
- The PR principal can create schemas in the catalog, so dbt PR builds (`pr_<n>_*`) don't need the
  deploying identity; it owns those schemas and drops them when the PR closes. It can't write to
  `bronze`, `silver` or `gold`, which the deploying principal owns.
- Two identities to maintain in `bootstrap.sh` and two repository variables (`AZURE_CLIENT_ID`,
  `AZURE_PR_CLIENT_ID`).
