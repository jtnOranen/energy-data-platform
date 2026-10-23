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

Done: phase 3's items (bronze freshness thresholds, ENTSO-E staging checks) and phase 4's CI/CD
hardening from the 2026-10-22 security review (read-only PR identity, SHA-pinned actions with
Dependabot, `dev` deployable only from `main`).

**Standing rule (public repo):** Terraform plan comments on PRs are public. Sensitive variables are
hidden; mark every new one `sensitive`.

**Phase 5 (monitoring)**
- Alert when a scheduled run fails (`bronze_load`, `dbt_build`, the ingestion functions) and when a
  `main` deploy fails. Today only the job pages show it; ENTSO-E's outage on 2026-10-22 (two failed
  function runs, HTTP 599) was found by hand.

**Phase 6 (polish)**
- An orphaned workspace catalog from the deleted hybrid workspace may remain in the metastore
  (ADR 0013); clean it up from the account console.
- Publish the dbt docs site (CI already builds it as an artifact).

## Report questions (phase 5)

1. How much of the price variation does wind production explain?
2. When does the price go negative, and what do those intervals have in common?
3. How does consumption follow temperature in winter?
4. What do the daily and weekly price profiles look like, and did 15-minute pricing change intra-hour variation?

Extensions: price-spike anatomy (top 1 % and negative intervals), pipeline-health dashboard
(dbt `run_results.json` + Databricks system tables), price forecast.
