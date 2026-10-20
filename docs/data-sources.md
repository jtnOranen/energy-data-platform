# Data sources

> Items marked **VERIFY** were not confirmed against the live documentation when this file was written.
> Check them before implementing, and update this file.

## Fingrid open data

| Item | Value |
| --- | --- |
| Docs | https://data.fingrid.fi/en/instructions, technical docs at https://developer-data.fingrid.fi |
| Base URL | `https://data.fingrid.fi/api` |
| Auth | Free API key (register, subscribe to "Open Data starter"), sent in header `x-api-key` |
| Limits | 1 request / 2 s and 10,000 requests / 24 h per key |
| Datasets | Wind power production, real-time, dataset **181** (3-minute resolution, MW). Consumption and total production: **VERIFY dataset IDs** on data.fingrid.fi |
| Endpoint shape | **VERIFY** in the developer portal (dataset data endpoint with start/end time and paging) |

Quirks: real-time values can be revised; 3-minute grain must be aggregated to 15 minutes in silver (mean MW).

## ENTSO-E Transparency Platform

| Item | Value |
| --- | --- |
| Docs | https://transparency.entsoe.eu (API guide), token via "My Account → Web API Security Token" after requesting access |
| Base URL | `https://web-api.tp.entsoe.eu/api` **VERIFY** |
| Auth | `securityToken` query parameter (free, request access by registering) |
| Dataset | Day-ahead prices: `documentType=A44`, `in_Domain` = `out_Domain` = `10YFI-1--------U` (bidding zone FI) **VERIFY** |
| Format | XML (`Publication_MarketDocument`), timestamps in UTC, prices EUR/MWh |

Quirks:
- Resolution changed from `PT60M` to `PT15M` for delivery day **2025-10-01** (SDAC 15-minute MTU go-live).
  Read the `resolution` element per period; never assume it.
- Periods can omit positions when the price repeats (curve type A03) **VERIFY**; forward-fill within the period.
- The market delivery day follows CET/CEST, i.e. 01:00–01:00 Finnish local time.

## Finnish Meteorological Institute (FMI) open data

| Item | Value |
| --- | --- |
| Docs | https://en.ilmatieteenlaitos.fi/open-data-manual |
| Base URL | `http://opendata.fmi.fi/wfs` (WFS 2.0, use https if supported **VERIFY**) |
| Auth | None in documented examples; users must accept the open data licence |
| Query | Stored query for weather observations, e.g. `fmi::observations::weather::timevaluepair` with `fmisid`, `parameters=t2m,ws_10min`, `starttime`, `endtime` **VERIFY** |
| Stations | Start with a handful of stations near wind power clusters and population centres (e.g. Helsinki-Vantaa, Oulu, Vaasa, Pori). Pick by `fmisid` |

Quirks: 10-minute observations; missing values appear as `NaN`; station metadata can change (handled as SCD2 in dbt).

## Ingestion rules (all sources)

- Fetch a window of **now − 48 h → now** every run, so late and revised data is picked up. Downstream dedupes.
- Write the raw response unchanged. Never transform in the Function.
- Backfill script loads history from **2024-01-01** so both 60- and 15-minute price grains are present.
- Log source, dataset, window, row count and HTTP status for every call.
