# Roadmap

Roughly 8 weeks at 6–8 hours per week. Each phase ends in something that works on its own.
Detailed specs live in `docs/phases/`. Write the next phase's spec before starting it.

| Phase | Weeks | Outcome | Done when |
| --- | --- | --- | --- |
| 0 Foundation | 1 | Repo, remote state, OIDC, ADLS, Key Vault, budget | A merged PR creates resources through GitHub Actions |
| 1 Ingestion | 2 | Azure Function + backfill for three sources | Landing has history since 2024-01-01 and new files every hour |
| 2 Databricks + bronze | 3 | Workspace, Unity Catalog, Auto Loader job as an Asset Bundle | Bronze tables update automatically |
| 3 dbt + star schema | 4–5 | Silver and gold models, snapshot, tests, contracts, docs | `dbt build` passes and gold answers the report questions |
| 4 CI/CD | 6 | PR checks and `main` deploy for all parts | Nothing reaches `main` without green checks |
| 5 Report + monitoring | 7 | Dashboard, price-spike analysis, pipeline-health page, alerts | Dashboard live, failures alert |
| 6 Polish | 8 | README, ADRs, cost report, rebuild test | `terraform destroy` + `apply` restores everything |
| Extension | later | Next-day price forecast with MLflow | Forecasts written back to a gold table |

## Backlog for later phases

Known gaps, recorded when found so the phase that owns them picks them up.

**Phase 3 (dbt)**
- Source freshness on bronze must allow for the 6-hourly bronze load (e.g. warn 8 h, error 24 h).
- Staging checks on ENTSO-E: `in_domain`, `currency_unit`, `price_measure_unit`, `curve_type` are all
  `10YFI-1--------U` / EUR / MWH / A03 today; test it rather than assume it.

**Phase 4 (CI/CD hardening)** — found in a security review on 2026-10-22:
- **Read-only identity for pull requests.** PR runs use the same service principal as `main`
  (Contributor on `rg-energy-dev`), so a workflow edited on a branch could change infrastructure.
  Only the owner can push today, so the risk is theoretical. Fix: a second service principal with
  `Reader` (+ state blob read and Databricks read) for the `pull_request` federated credential; the
  current one keeps only the `main` and `environment:dev` credentials.
- **Pin third-party actions to commit SHAs** instead of tags, so a compromised action release can't
  move a tag under us (Dependabot can keep the SHAs current).
- **Environment protection on `dev`**: limit deployments to `main` (and optionally a required
  reviewer), so even a misconfigured workflow can't deploy from a branch.
- **Plan comments are public** (public repo). Sensitive variables are already hidden; keep checking
  new ones are marked `sensitive`.

**Phase 6 (polish)**
- An orphaned workspace catalog from the deleted hybrid workspace may remain in the metastore
  (ADR 0013); clean it up from the account console.

## Report questions (phase 5)

1. How much of the price variation does wind production explain?
2. When does the price go negative, and what do those intervals have in common?
3. How does consumption follow temperature in winter?
4. What do the daily and weekly price profiles look like, and did 15-minute pricing change intra-hour variation?

Extensions: price-spike anatomy (top 1 % and negative intervals), pipeline-health dashboard
(dbt `run_results.json` + Databricks system tables), price forecast.
