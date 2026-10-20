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
(e.g. a GitHub environment) needs its own credential.

The `pull_request` trigger's federated credential subject (`repo:<owner>/<repo>:pull_request`) does
not distinguish a PR from this repository from a PR opened from a fork -- the OIDC token's `sub`
claim is identical either way. Since this repo is public, anyone can open a fork PR. `.github/workflows/terraform.yml`
therefore gates every step that would request that token (`init`, `validate`, `plan`) on
`github.event.pull_request.head.repo.full_name == github.repository`, so a fork PR only ever runs
`terraform fmt` (no credentials needed) instead of getting a token for the `Contributor` +
`Role Based Access Control Administrator` service principal. This is enforced in the workflow itself,
not left to GitHub's (configurable, clickable) "approve fork PR workflow run" setting.
