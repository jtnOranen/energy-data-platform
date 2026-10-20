# Phase 1 — Ingestion

## Goal

An Azure Function fetches Fingrid, ENTSO-E and FMI every hour and writes the raw responses to the ADLS
`landing` container. A backfill script loads history from 2024-01-01. No transformation anywhere.

Done when (from `docs/roadmap.md`): **landing has history since 2024-01-01 and new files every hour.**

## Out of scope

Databricks, bronze tables, dbt, alerting (phase 5). Nothing reads `landing` yet.

## Manual prerequisites (owner does these; start the ENTSO-E one first)

1. **ENTSO-E token**: register on the Transparency Platform, then request REST API access (email to the
   platform's support address, per their API guide). Approval can take days.
2. **Fingrid API key**: register on data.fingrid.fi and subscribe to "Open Data starter".
3. After this phase's Terraform is applied, put both values in Key Vault yourself (never via Terraform,
   so they never land in state):
   `az keyvault secret set --vault-name <kv> --name fingrid-api-key --value ...` and `entsoe-token`.
4. Tools: Azure Functions Core Tools v4 (to run the function locally).

## Step 0: verify the sources

Before writing any client code, resolve every **VERIFY** in `docs/data-sources.md` against the live
documentation and update that file in the same PR. In addition, find out:

- Fingrid: dataset IDs for consumption and total production; page size limit; how paging works.
- ENTSO-E: maximum time range per A44 request (needed for backfill chunking).
- FMI: maximum time span per observation query (needed for backfill chunking); whether https works.
- Azure: Flex Consumption availability and supported Python versions in `swedencentral`.

## Deliverables

### 1. Terraform (`infra/`)

New module `infra/modules/function_app/`, called from `envs/dev/main.tf`:

- Log Analytics workspace + workspace-based Application Insights (the function's logs go here).
- Host storage account for the function (separate from the ADLS account: host storage should not have a
  hierarchical namespace) with a deployment container.
- Function app, **Flex Consumption** plan, Python 3.12 (or newest supported, see step 0),
  system-assigned managed identity. Host storage uses the identity (`storage_authentication_type =
  SystemAssignedIdentity`), not a connection string.
- App settings: `FINGRID_API_KEY` and `ENTSOE_TOKEN` as **Key Vault references**
  (`@Microsoft.KeyVault(SecretUri=...)`), plus the ADLS account name and container. No secret values.

Role assignments (all least privilege, all inside `rg-energy-dev`):

| Principal | Role | Scope |
| --- | --- | --- |
| Function identity | Key Vault Secrets User | the Key Vault |
| Function identity | Storage Blob Data Contributor | the `landing` container (not the account) |
| Function identity | roles Flex Consumption needs on its host storage | host storage account |
| Owner | Storage Blob Data Contributor | the `landing` container (for the backfill) |

### 2. Python project (`ingestion/`)

```
ingestion/
├── pyproject.toml          uv-managed; ruff and pytest config
├── function_app.py         three timer triggers (Python v2 programming model)
├── src/ingestion/
│   ├── window.py           fetch window: now - 48 h → now, UTC, truncated to the hour
│   ├── landing.py          blob path + upload (azure-storage-blob, DefaultAzureCredential)
│   ├── fingrid.py          client: x-api-key header, paging, 2 s spacing, 429 backoff
│   ├── entsoe.py           client: securityToken, A44 for 10YFI-1--------U
│   └── fmi.py              client: WFS stored query per station
├── backfill.py             CLI: source, start, end → chunked fetches into landing
└── tests/
    ├── fixtures/           recorded responses (API key/token stripped from anything saved)
    └── test_*.py
```

Behaviour:

- **One timer function per source** (Fingrid, ENTSO-E, FMI), so one failing API doesn't stop the others.
  All three Fingrid datasets run sequentially in the Fingrid function, because the rate limit
  (1 request / 2 s) is per API key.
- **Write the raw response bytes unchanged.** No parsing beyond what's needed to page and to detect errors.
- **Path:** `landing/<source>/<dataset>/yyyy=YYYY/mm=MM/dd=DD/<ingested_at>.<ext>`, where the date is the
  ingestion time in UTC and `<ext>` is `json` or `xml` per source. Never overwrite an existing blob.
- **Error responses are failures, not data.** In particular, ENTSO-E returns an
  `Acknowledgement_MarketDocument` (HTTP 200) when there is no data; FMI returns an exception report.
  Log these and don't write them to landing.
- **Log every call:** source, dataset, window, row/record count, HTTP status.
- Same client code in the function and in `backfill.py`. The backfill runs locally as the owner
  (`az login`, reads the keys from Key Vault), chunked to each API's maximum range, and respects the same
  rate limits.

Tests (no network, per `docs/conventions.md`):

- window computation, including a DST transition date (the window is UTC, so it must not shift);
- blob path building;
- Fingrid paging over multi-page fixtures; 429 handling;
- ENTSO-E: acknowledgement document is treated as "no data", both 60- and 15-minute responses are passed
  through unchanged;
- FMI: exception report is treated as an error;
- backfill chunking: a 2024-01-01 → today range splits into chunks within each API's limit.

### 3. CI for `ingestion/`

`.github/workflows/ingestion.yml`: on PRs touching `ingestion/**`, run `uv sync`,
`uv run ruff check .`, `uv run ruff format --check .`, `uv run pytest`.

Deployment: see open decision 1.

### 4. Docs

- `docs/data-sources.md`: all VERIFY items resolved.
- ADRs for the decisions below once accepted.
- README: how to run the backfill (a few lines).

## Open decisions (owner)

1. **How the function code gets deployed in this phase.**
   (a) Add a deploy job to `ingestion.yml` now (push to `main`, OIDC, `dev` environment, same pattern as
   Terraform). (b) Deploy manually with `func azure functionapp publish` in this phase and add CD in phase 4,
   which the roadmap defines as "CI/CD for all parts".
   *Recommendation: (a).* The Terraform workflow already established the pattern, so it's a small
   addition, and it avoids a manual deploy step that phase 4 would just replace. This pulls a bit of phase 4
   forward, so it needs your explicit OK.
2. **Function app name.** `docs/conventions.md` says `func-energy-ingest-dev`, but function app names are
   globally unique (`*.azurewebsites.net`), like storage accounts. (a) Keep it and hope it's free.
   (b) Add the random suffix: `func-energy-ingest-dev-<suffix>`, and update the conventions.
   *Recommendation: (b)*, for the same reason the storage and Key Vault names have one.
3. **Hosting plan.** (a) Flex Consumption. (b) The older Linux Consumption plan.
   *Recommendation: (a).* It's the plan Microsoft recommends for new apps, and it supports identity-based
   host storage, so there's no storage connection string anywhere. Record as an ADR.

## Acceptance criteria

- [ ] All VERIFY items in `docs/data-sources.md` are resolved.
- [ ] `terraform plan` after apply shows no changes (the apply job checks this automatically).
- [ ] No secret values in the repo, in Terraform state, or in app settings (only Key Vault references).
- [ ] `uv run pytest` and ruff pass locally and in CI; no test touches the network.
- [ ] Each timer function has run in Azure and written a file per dataset to landing; App Insights shows
      the per-call log lines.
- [ ] Backfill has loaded 2024-01-01 → today for every dataset, so both the 60- and the 15-minute
      ENTSO-E price grains (before and after 2025-10-01) are in landing.
- [ ] Two consecutive hourly runs both succeed; the second writes new files (overlapping data is expected).

## Interview notes to capture (in README or ADRs)

- Why write raw responses unchanged, and why a 48-hour overlap window instead of "since last run".
- Why Key Vault references and an identity-based host storage connection instead of connection strings.
- Why one function per source.
- How the backfill stays within the rate limits.
