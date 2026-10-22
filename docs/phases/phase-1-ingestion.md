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
documentation and update that file.

Done on 2026-10-20 (results are in `docs/data-sources.md`): Fingrid dataset IDs (switched to the
15-minute datasets, ADR 0009); ENTSO-E endpoint, rate limit and one-year range limit; FMI https,
168-hour limit and the `timestep=10` requirement; Flex Consumption in `swedencentral` (Python 3.10–3.14).

Fingrid was verified with the key on 2026-10-20: endpoint, paging (max 20,000 per page),
`startTime`/`endTime` per record, and gaps in the data. ENTSO-E was verified with the token the same
day: FI EIC code, 60- and 15-minute documents, curve type A03 omitting about a third of the periods'
repeated positions, and "no data" coming back as HTTP 200. Step 0 is complete.

## Deliverables

### 1. Terraform (`infra/`)

New module `infra/modules/function_app/`, called from `envs/dev/main.tf`:

- Log Analytics workspace + workspace-based Application Insights (the function's logs go here), with
  local authentication disabled so the function sends telemetry with its identity.
- Host storage account for the function (separate from the ADLS account: host storage should not have a
  hierarchical namespace) with a deployment container.
- Function app, **Flex Consumption** plan, **Python 3.13** (supported on Flex in `swedencentral` until
  2029-10; 3.14 is available too, but staying one release behind the newest is safer for third-party
  wheels), system-assigned managed identity. Host and deployment storage use the identity, not a
  connection string. The function app is an `azapi_resource`, because azurerm 4.81's Flex resource
  can't do identity-based host storage correctly (ADR 0010).
- App settings: `FINGRID_API_KEY` and `ENTSOE_TOKEN` as **Key Vault references**
  (`@Microsoft.KeyVault(SecretUri=...)`), plus the ADLS account name and container. No secret values.

Role assignments (all least privilege, all inside `rg-energy-dev`):

| Principal | Role | Scope |
| --- | --- | --- |
| Function identity | Key Vault Secrets User | the Key Vault |
| Function identity | Storage Blob Data Contributor | the `landing` container (not the account) |
| Function identity | Storage Blob Data Owner (host storage and deployment package) | host storage account |
| Function identity | Monitoring Metrics Publisher | Application Insights |
| Owner | Storage Blob Data Contributor | the `landing` container (for the backfill) |

### 2. Python project (`ingestion/`)

```
pyproject.toml              uv workspace root: dev tools (ruff, pytest), ruff/pytest config
uv.lock, .python-version    locked dependencies, Python 3.13
ingestion/
├── pyproject.toml          workspace member `energy-ingest` (runtime dependencies)
├── function_app.py         timer triggers (Python v2 programming model)
├── host.json, .funcignore
├── energy_ingest/          the package, at the app root so the Functions host can import it
│   ├── window.py           fetch window: now - 48 h → now, UTC, truncated to the hour; split()
│   ├── landing.py          blob path + upload (azure-storage-blob, DefaultAzureCredential)
│   ├── transport.py        rate limiter, retries on 429/5xx (Retry-After), SourceError
│   ├── fingrid.py          client: x-api-key header, paging, 3 s spacing
│   ├── entsoe.py           client: securityToken, A44 for 10YFI-1--------U (when the token arrives)
│   ├── fmi.py              client: WFS stored query per station, timestep=10, ≤ 168 h per call
│   └── run.py              fetch → landing per source, shared by the function and the backfill
├── backfill.py             CLI: source, start, end → chunked fetches into landing
└── tests/
    ├── fixtures/           recorded responses (no keys in them)
    └── test_*.py
```

A workspace root lets `uv sync` / `uv run pytest` work from the repo root (CLAUDE.md), and dbt can
join as another member later. `requirements.txt` for the function's remote build is generated from
`uv.lock` in CI (`uv export`), not committed.

Behaviour:

- **One timer function per source** (Fingrid, ENTSO-E, FMI), so one failing API doesn't stop the others.
  All three Fingrid datasets run sequentially in the Fingrid function, because the rate limit
  (1 request / 2 s) is per API key. Within a source, one failing dataset or station doesn't stop the
  others; the run is marked failed at the end.
- **Write the raw response bytes unchanged.** No parsing beyond what's needed to page and to detect errors.
- **Path:** `landing/<source>/<dataset>/yyyy=YYYY/mm=MM/dd=DD/<ingested_at>_<start>_<end>[_<key>]_p<part>.<ext>`,
  where the date is the ingestion time in UTC, `<key>` identifies e.g. the FMI station, `<part>` is the page
  or chunk, and `<ext>` is `json` or `xml`. Every response gets its own blob; nothing is overwritten.
- **ENTSO-E note for later:** day-ahead prices are published around midday for the *next* day, so a window
  ending "now" only picks a price up once its delivery hour has passed. That's enough for the historical
  analysis, but the forecast extension would need the ENTSO-E window to reach into the future.
- **Error responses are failures, not data.** In particular, ENTSO-E returns an
  `Acknowledgement_MarketDocument` (HTTP 200) when there is no data; FMI returns an exception report.
  Log these and don't write them to landing.
- **Log every call:** source, dataset, window, row/record count, HTTP status.
- Same client code in the function and in `backfill.py`. The backfill runs locally as the owner
  (`az login`, reads the keys from Key Vault), chunked to each API's maximum range, and respects the same
  rate limits. Its Key Vault client (`azure-keyvault-secrets`) is in the workspace root's `ops`
  dependency group, so it isn't deployed with the function. Backfilled files land in the partition of
  the day the backfill ran, since the partition is the ingestion date; the window is in the file name.

Tests (no network, per `docs/conventions.md`):

- window computation, including a DST transition date (the window is UTC, so it must not shift);
- blob path building;
- Fingrid paging over multi-page fixtures; 429 handling;
- ENTSO-E: acknowledgement document is treated as "no data", both 60- and 15-minute responses are passed
  through unchanged;
- FMI: exception report (e.g. HTTP 400 "Too long time interval requested") is treated as an error;
  requests always include `timestep=10`;
- backfill chunking: a 2024-01-01 → today range splits into chunks within each API's limit.

### 3. CI/CD for `ingestion/`

`.github/workflows/ingestion.yml`:

- On PRs touching `ingestion/**` (or the workflow file): `uv sync`, `uv run ruff check .`,
  `uv run ruff format --check .`, `uv run pytest`.
- On push to `main` (same paths): the same checks, then a deploy job in the `dev` environment that
  authenticates with OIDC and deploys the function code. The `environment:dev` federated credential from
  phase 0 already covers this job; the SP's `Contributor` on `rg-energy-dev` covers the deploy.
- Fork PRs run the checks only, which need no Azure credentials anyway.

This pulls part of phase 4 ("CI/CD for all parts") forward, by the owner's decision (see below).

### 4. Docs

- `docs/data-sources.md`: all VERIFY items resolved.
- ADR 0008 (hosting plan) is written with this spec; add more ADRs if implementation forces other lasting
  decisions.
- README: how to run the backfill (a few lines).

## Decisions (made by the owner on 2026-10-20)

1. **Deploy the function from CI in this phase**, not manually. The deploy job uses the same pattern as the
   Terraform apply job, and there's no manual deploy step for phase 4 to replace later.
2. **Function app name gets the random suffix:** `func-energy-ingest-dev-<suffix>`, because function app
   names are globally unique (`*.azurewebsites.net`). `docs/conventions.md` is updated.
3. **Flex Consumption hosting plan.** See ADR 0008.

## Acceptance criteria

Checked 2026-10-20 (PRs #2–#9). One item is open, see below.

- [x] All VERIFY items in `docs/data-sources.md` are resolved.
- [x] `terraform plan` after apply shows no changes (the apply job checks this automatically).
- [x] No secret values in the repo, in Terraform state, or in app settings (only Key Vault references).
      Repo and app settings: yes (gitleaks clean; the API keys are Key Vault references; the App Insights
      connection string can't ingest anything with local auth disabled). Terraform state:
      `azurerm_storage_account` always stores both storage accounts' access keys in state, even though
      nothing uses them. **Resolved 2026-10-22** (during phase 2): Shared Key is disabled on both
      accounts and the azurerm provider uses Entra ID for storage (`storage_use_azuread`), so the keys in
      state can't authorize anything.
- [x] `uv run pytest` and ruff pass locally and in CI; no test touches the network (38 tests; httpx
      without an explicit transport fails in tests).
- [x] Each timer function has run in Azure and written a file per dataset to landing; App Insights shows
      the per-call log lines (first runs 14:05/14:10/14:15 UTC; 0 exceptions; no `securityToken` in logs).
- [x] Backfill has loaded 2024-01-01 → today for every dataset, so both the 60- and the 15-minute
      ENTSO-E price grains (before and after 2025-10-01) are in landing. FMI is complete (147,415 points
      per station); Fingrid is missing only its known gaps (about 350 quarter-hours per dataset).
- [x] Two consecutive hourly runs both succeed; the second writes new files (overlapping data is
      expected). Four consecutive successful runs per function, 14:05–17:15 UTC.

## Interview notes to capture (in README or ADRs)

- Why write raw responses unchanged, and why a 48-hour overlap window instead of "since last run".
- Why Key Vault references and an identity-based host storage connection instead of connection strings.
- Why one function per source.
- How the backfill stays within the rate limits.
