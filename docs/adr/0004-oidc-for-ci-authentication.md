# 0004 — OIDC for GitHub Actions authentication

- Status: accepted
- Date: 2026-10-20

## Context

GitHub Actions must authenticate to Azure (Terraform, deployments) and later to Databricks.

## Options

1. Service principal client secret stored in GitHub secrets — simple, but a long-lived credential that must be rotated.
2. OIDC federated credentials — short-lived tokens issued per workflow run, scoped to repo and branch/PR.

## Decision

OIDC. Federated credentials for `main` and `pull_request`. Only non-secret IDs are stored as repo variables.

## Consequences

No secret to leak or rotate. Federated credential subjects must match exactly; a new trigger type
needs its own credential. In particular, a job that declares `environment: dev` (the apply job)
presents `...:environment:dev` instead of `...:ref:refs/heads/main`, so there are three credentials:
`main`, `pull_request` and `environment:dev`.

The `pull_request` subject does not by itself distinguish a PR from this repository from a PR
opened from a fork. GitHub already caps fork-PR runs to a read-only token by default, which
should stop them from obtaining an OIDC token at all. As defense in depth (so this doesn't depend
on that default or on the "approve fork PR workflow run" setting), `.github/workflows/terraform.yml`
also gates every step that would request the token (`init`, `validate`, `plan`) on
`github.event.pull_request.head.repo.full_name == github.repository`. A fork PR only runs
`terraform fmt`, which needs no credentials.
