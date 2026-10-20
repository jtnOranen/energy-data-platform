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

## Report questions (phase 5)

1. How much of the price variation does wind production explain?
2. When does the price go negative, and what do those intervals have in common?
3. How does consumption follow temperature in winter?
4. What do the daily and weekly price profiles look like, and did 15-minute pricing change intra-hour variation?

Extensions: price-spike anatomy (top 1 % and negative intervals), pipeline-health dashboard
(dbt `run_results.json` + Databricks system tables), price forecast.
