# Conventions

## Naming

| Thing | Pattern | Example |
| --- | --- | --- |
| Resource group | `rg-<project>-<env>` | `rg-energy-dev` |
| Storage account | `st<project><env><suffix>` (≤ 24, lowercase alphanumeric) | `stenergydevx7k2` |
| Key Vault | `kv-<project>-<env>-<suffix>` (≤ 24) | `kv-energy-dev-x7k2` |
| Function app | `func-<project>-ingest-<env>-<suffix>` (globally unique) | `func-energy-ingest-dev-x7k2` |
| Databricks workspace | `dbw-<project>-<env>` | `dbw-energy-dev` |
| Tags (all resources) | `project`, `env`, `owner`, `managed_by=terraform` | |
| dbt models | `stg_<source>__<entity>`, `int_<entity>_<grain>`, `fct_…`, `dim_…` | `stg_entsoe__day_ahead_price` |
| Columns | snake_case; UTC timestamps end in `_utc`; units in the name | `wind_production_mw`, `price_eur_mwh` |

A random `suffix` comes from `random_string` in Terraform so names stay unique.

## Terraform

- Modules in `infra/modules/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`, `README.md`.
- Pin provider major versions in `versions.tf`; commit `.terraform.lock.hcl`.
- No hard-coded subscription or tenant IDs; pass via variables or environment.
- Every variable has a `description` and a `type`.

## Python

- Python 3.11+, dependencies with `uv` in `pyproject.toml`.
- `ruff` for lint and format. Type hints on public functions.
- No network calls in unit tests; use recorded fixtures in `tests/fixtures/`.

## SQL / dbt

- `sqlfluff` with the dbt templater, lowercase keywords.
- CTE style: import CTEs first, then logic, then `final`.
- Every model has a YAML entry with description and tests.

## Git

- Branches: `feat/`, `fix/`, `chore/`, `docs/`. Conventional Commits.
- `main` is protected: PR + green checks required. Squash merge.
