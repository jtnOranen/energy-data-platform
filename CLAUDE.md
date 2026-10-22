# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this project is

A portfolio data platform that answers: **how do wind power and weather show up in the Finnish day-ahead electricity price?**
Data from Fingrid, ENTSO-E and the Finnish Meteorological Institute (FMI) is loaded to Azure, transformed in
Databricks with dbt, and reported in a Databricks AI/BI dashboard. Everything is deployed with Terraform and
GitHub Actions.

The owner is building this **to learn and to show skills to employers**. That changes how you should work:

- Explain *why* when you make a non-obvious choice, briefly. The owner must be able to defend every line in an interview.
- Prefer the simple, conventional solution over the clever one.
- When there are two reasonable options, name both in one sentence each and recommend one. Record lasting
  decisions as an ADR in `docs/adr/`.
- Communicate with the owner in **Finnish**. Write code, comments, commit messages and docs in **English**.

## Read before working

| File | Read when |
| --- | --- |
| `docs/architecture.md` | always, before any change |
| `docs/roadmap.md` | to see which phase is current and what "done" means |
| `docs/phases/phase-N-*.md` | before implementing anything in phase N |
| `docs/data-sources.md` | before touching ingestion |
| `docs/data-model.md` | before touching Databricks or dbt |
| `docs/conventions.md` | before naming anything |
| `docs/adr/` | before reversing an earlier decision |

## Working agreements

1. **One phase at a time.** Only implement what the current phase spec asks for. If something from a later phase
   seems needed, stop and say so.
2. **Small pull requests.** One logical change per branch: `feat/…`, `fix/…`, `chore/…`, `docs/…`.
   Conventional Commits for messages.
3. **Verify before claiming done.** Run the relevant checks and show the output:
   - Terraform: `terraform fmt -recursive -check` and `terraform validate`
   - Python: `uv run ruff check .`, `uv run ruff format --check .`, `uv run pytest`
   - dbt: `dbt build --select <changed models>+`
4. **Never run `terraform apply` or `terraform destroy` locally.** Infrastructure changes go through a pull request
   and GitHub Actions. `terraform plan` locally is fine.
5. **No secrets in the repo, ever.** API keys live in Azure Key Vault and GitHub uses OIDC. If you see a secret
   in a file or diff, stop and tell the owner.
6. **Update docs in the same PR** when behaviour, structure or a decision changes.
7. **Tests come with the code.** Ingestion parsers get pytest tests with recorded fixtures; dbt models get tests
   as specified in `docs/data-model.md`.

## Repository layout

```
infra/          Terraform (modules/ + envs/dev/), bootstrap script for remote state
ingestion/      Azure Function app (Python) + backfill script + tests
databricks/     Databricks Asset Bundle (jobs, Auto Loader notebooks/scripts)
dbt/            dbt project (staging, intermediate, marts, snapshots)
.github/        GitHub Actions workflows
docs/           architecture, roadmap, phase specs, ADRs
```

## Commands

```bash
# Python (from repo root)
uv sync
uv run pytest
uv run ruff check . && uv run ruff format --check .

# Terraform (from infra/envs/dev)
terraform init
terraform fmt -recursive -check
terraform validate
terraform plan

# Databricks (from databricks/)
databricks bundle validate

# dbt (from dbt/)
dbt deps
dbt build
```

## Things that are easy to get wrong here

- **All timestamps are UTC** from the bronze layer onward. Convert local time only in the report layer.
- **Price grain changed** from 60 minutes to 15 minutes for delivery day 2025-10-01. The model must handle both.
- **Daylight saving time:** a Finnish local day has 92 or 100 quarter-hours on transition days; a UTC day always has 96.
- **Fingrid rate limit:** 1 request per 2 seconds and 10,000 requests per 24 h per API key.
- **Storage account and Key Vault names** are globally unique. Key Vault soft delete keeps a name reserved after destroy.
- **GitHub OIDC federated credential subjects** must include the owner's and repo's immutable numeric IDs
  (`repo:<owner>@<owner_id>/<repo>@<repo_id>:...`), not just their names — GitHub's token `sub` claim includes
  them, and Azure rejects a mismatch with `AADSTS700213`. `bootstrap.sh` fetches them via `gh api`.
- **Git Bash / MSYS2 on Windows rewrites `/subscriptions/...`-style arguments as Windows paths** before
  they reach `az.exe`, breaking `--scope`. `bootstrap.sh` sets `MSYS_NO_PATHCONV=1` itself; do the same
  for any ad hoc `az` command with a `/subscriptions/...` scope run directly in Git Bash.
- **The function app is an `azapi_resource`, not `azurerm_function_app_flex_consumption`.** azurerm 4.81 injects
  a keyless `AzureWebJobsStorage` string that breaks identity-based host storage (ADR 0010). Don't "clean it
  up" back to azurerm until hashicorp/terraform-provider-azurerm#29099 is released. After the function app is
  first created, restart it once, or its Key Vault references stay `AccessToKeyVaultDenied` (see the module README).
- **Resource groups are created by `bootstrap.sh`, not Terraform** (`data`, not `resource`, in
  `envs/dev/main.tf`) — so the CI service principal's roles stay scoped to `rg-energy-dev` instead of
  the whole (personal) subscription. See ADR 0007. A new resource group in a later phase needs the same
  treatment, not a Terraform-created one.
- **The Databricks workspace is created by `bootstrap.sh` too** (data source in Terraform), because its
  managed resource group is a subscription-level operation (ADR 0012). Don't move it into Terraform.
  Unity Catalog objects and the access connector *are* Terraform. `bootstrap.sh` also makes the CI
  service principal a workspace admin: with GitHub OIDC auth (`github-oidc-azure`) Databricks doesn't
  auto-provision a Contributor SP the way it does with a client secret.
