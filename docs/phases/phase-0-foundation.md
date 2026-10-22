# Phase 0 — Foundation

## Goal

A merged pull request creates the base Azure resources through GitHub Actions, authenticated with OIDC,
with Terraform state in Azure. No application code yet.

## Out of scope

Function app, Databricks, dbt. Do not create them in this phase.

## Manual prerequisites (owner does these, Claude Code writes the script and docs)

1. Tools installed: Azure CLI, Terraform, GitHub CLI, uv.
2. GitHub repo `energy-data-platform` exists, public, `main` protected (PR + status checks required).
3. Azure subscription available; owner is logged in with `az login`.

## Deliverables

### 1. `infra/bootstrap/bootstrap.sh`

Idempotent script the owner runs **once** locally. It:

- creates resource group `rg-energy-tfstate` and a storage account (`stenergytfstate<suffix>`, Standard_LRS,
  TLS 1.2, no public blob access, blob versioning on) with container `tfstate`;
- creates an Entra ID app registration + service principal `gh-energy-data-platform`;
- adds three federated credentials (subjects use GitHub's immutable IDs, `<owner>@<owner_id>/<repo>@<repo_id>`):
  - `repo:<owner>@<id>/energy-data-platform@<id>:ref:refs/heads/main` (plan job on push to `main`)
  - `repo:<owner>@<id>/energy-data-platform@<id>:pull_request` (plan job on PRs)
  - `repo:<owner>@<id>/energy-data-platform@<id>:environment:dev` (apply job, which runs in the `dev` environment)
  (issuer `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`);
- assigns roles to the service principal:
  - `Contributor` on the subscription,
  - `Role Based Access Control Administrator` on the subscription (needed later for managed identity role assignments),
  - `Storage Blob Data Contributor` on the state storage account;
- sets GitHub repo **variables** (not secrets) with `gh variable set`: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`, `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`;
- prints what it created. Re-running must not fail or duplicate.

Takes `GITHUB_OWNER` and `LOCATION` (default `swedencentral`) as inputs.

### 2. Terraform `infra/`

```
infra/
├── bootstrap/bootstrap.sh
├── modules/
│   ├── storage/      ADLS Gen2 account (is_hns_enabled = true) + container `landing`
│   ├── key_vault/    Key Vault, RBAC authorization, soft delete 7 days, purge protection off (dev)
│   └── budget/       Consumption budget on the resource group with email alert
└── envs/dev/
    ├── versions.tf   required_version, azurerm + random pinned to major versions
    ├── backend.tf    azurerm backend, use_oidc = true, use_azuread_auth = true (values via -backend-config)
    ├── main.tf       resource group rg-energy-dev, random suffix, module calls, common tags
    ├── variables.tf  location, budget_amount_eur, alert_email, owner
    └── outputs.tf    storage account name, key vault name, resource group name
```

- Common tags: `project = "energy"`, `env = "dev"`, `owner`, `managed_by = "terraform"`.
- Names follow `docs/conventions.md`.
- The owner gets `Key Vault Secrets Officer` on the vault so they can add API keys in phase 1.

### 3. `.github/workflows/terraform.yml`

- Triggers: `pull_request` (paths `infra/**`, the workflow file) and `push` to `main` (same paths).
- `permissions: id-token: write, contents: read, pull-requests: write`.
- Env: `ARM_USE_OIDC=true`, `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` from repo variables.
- Steps: checkout → setup Terraform → `terraform fmt -recursive -check` → `init` with backend config from repo
  variables → `validate` → `plan -out=tfplan`.
- On PR: post the plan as a PR comment (update the same comment on new pushes).
- On `main`: `terraform apply tfplan`. Use a GitHub environment `dev` for the apply job.
- After apply, the same job runs `terraform plan -detailed-exitcode` and fails if it reports changes
  (automates the "plan after apply shows no changes" acceptance criterion below).
- Concurrency group per branch so two applies never run at once.

### 4. Repo hygiene

- `.gitignore` (Terraform, Python, `.env`, `*.tfvars` except `example.tfvars`).
- `.pre-commit-config.yaml`: `terraform_fmt`, `terraform_validate`, ruff, trailing whitespace, detect-secrets or gitleaks.
- `README.md` skeleton (see template in repo) with a "Bootstrap" section.
- `docs/adr/0001` – `0005` present.

## Acceptance criteria

Done 2026-10-20 (PR #1).

- [x] `bootstrap.sh` runs twice without errors; the second run changes nothing.
- [x] A PR touching `infra/` shows `fmt`, `validate` and `plan` green and a plan comment.
- [x] Merging that PR runs `apply` and creates the ADLS account with `landing`, the Key Vault and the budget.
      (`rg-energy-dev` itself is created by `bootstrap.sh` instead, see ADR 0007.)
- [x] No secret values exist anywhere in the repo or in GitHub secrets (gitleaks clean; no GitHub secrets used).
- [x] `terraform plan` after apply shows no changes (checked automatically by the apply job).
- [x] README explains bootstrap in under 10 lines.

## Interview notes to capture (in README or ADRs)

- Why state is bootstrapped outside Terraform.
- Why OIDC instead of a client secret.
- Why the SP needs RBAC Administrator and the risk that carries (scope it to the resource group later if possible).
