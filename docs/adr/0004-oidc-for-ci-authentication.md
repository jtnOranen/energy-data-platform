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
