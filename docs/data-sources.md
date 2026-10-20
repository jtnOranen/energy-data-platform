# Data sources

> Items marked **VERIFY** have not yet been confirmed against the live API. The rest were checked on
> 2026-10-20 (phase 1, step 0) against the official documentation or by calling the API directly.

## Fingrid open data

| Item | Value |
| --- | --- |
| Docs | https://data.fingrid.fi/en/instructions, technical docs at https://developer-data.fingrid.fi |
| Base URL | `https://data.fingrid.fi/api` (returns 401 without a key) |
| Auth | Free API key (register, subscribe to "Open Data starter"), sent in header `x-api-key` |
| Limits | 1 request / 2 s and 10,000 requests / 24 h per key. A live run still got HTTP 429 with exactly 2 s between requests, so the client waits 3 s |
| Datasets | **75** wind power generation (MW), **124** electricity consumption in Finland (MWh/h), **74** electricity production in Finland (MWh/h). All three are 15-minute data from 2023-06-13 and hourly before that. See ADR 0009 for why these and not the 3-minute real-time datasets (181, 193, 192) |
| Endpoint | `GET /datasets/{id}/data?startTime=…&endTime=…&format=json&pageSize=…&page=…` (times in ISO 8601 UTC) |
| Paging | `page` starts at 1; `pageSize` max **20,000** (larger returns HTTP 422 "max 20000"). Response: `{"data": [...], "pagination": {"total", "currentPage", "lastPage", "nextPage", ...}}`; `nextPage` is `null` on the last page |
| Record | `{"datasetId": 75, "startTime": "2025-01-01T01:45:00.000Z", "endTime": "2025-01-01T02:00:00.000Z", "value": 2260.8}`. Newest first by default |

Quirks:
- Each record has both `startTime` and `endTime` (UTC), so there is no ambiguity about which end of
  the interval a value belongs to, even though Fingrid's description of dataset 124 talks about
  end-of-interval timestamps. Use `startTime` as `interval_start_utc`.
- **The data has gaps.** Dataset 75 for 2024: 34,790 records instead of 35,136 intervals. 377
  intervals are missing over 79 days, at worst 17 on 2024-09-05. One record spans 30 minutes instead
  of 15. There are no duplicate start times. Don't assume 96 records per UTC day: build the fact table
  from a time spine and leave missing intervals null.
- A window `startTime=00:00, endTime=02:00` returns intervals starting 00:00 … 01:45 (start-inclusive).
- MWh/h over 15 minutes is the same quantity as average MW, so the three datasets can be compared directly.
- A malformed `x-api-key` header value gets an HTML "The request is blocked" page (HTTP 403) from
  Fingrid's firewall, not a JSON 401. A wrong key in Key Vault looks like this.

## ENTSO-E Transparency Platform

| Item | Value |
| --- | --- |
| Docs | Transparency Platform knowledge base (transparencyplatform.zendesk.com, "Restful API integration guide"); the old static guide on transparency.entsoe.eu now points there |
| Base URL | `https://web-api.tp.entsoe.eu/api` (https only; returns 401 without a token) |
| Auth | `securityToken` query parameter. Register, then request REST API access by email (subject "Restful API access") |
| Limits | 400 requests / minute **per token** (not per IP). Exceeding it gives HTTP 429 and a temporary ban of about 10 minutes. Day-ahead prices (article 12.1.D): at most a **one-year** date range per request |
| Dataset | Day-ahead prices: `documentType=A44`, `in_Domain` = `out_Domain` = `10YFI-1--------U` (bidding zone FI, confirmed in responses) |
| Request | `periodStart` / `periodEnd` as `yyyyMMddHHmm` in UTC; the token is the `securityToken` **query parameter**, so request URLs must never be logged |
| Format | XML (`Publication_MarketDocument`), timestamps in UTC, prices EUR/MWh (`currency_Unit.name` EUR, `price_Measure_Unit.name` MWH). A query for energy prices always returns whole delivery days |

Quirks (verified on 2026-10-20 against 2024–2025 data):
- Resolution changed from `PT60M` to `PT15M` for delivery day **2025-10-01** (SDAC 15-minute MTU go-live):
  2025-09-29 has 24 hourly points, 2025-10-02 has 96 quarter-hour points. Read the `resolution` element per
  period; never assume it.
- **Every period uses curve type A03, and positions are omitted when the price repeats.** In 2024–2025,
  226 of 731 periods (31 %) omit at least one position, 734 positions in total. Position 1 is never
  omitted, so forward-filling within the period always has a starting value. Expand the positions
  before joining.
- One period per delivery day (CET/CEST, i.e. 01:00–01:00 Finnish local time): 23 hours on the spring DST
  day and 25 on the autumn one, so a 15-minute period can have 92 or 100 positions.
- **"No data" is HTTP 200** with an `Acknowledgement_MarketDocument` (reason code 999, "No matching data
  found…"), so the status code alone isn't enough. A range over one year is HTTP 400 with the same
  document type ("…larger than maximum allowed period 'P1Y'…"). Neither is written to landing.

## Finnish Meteorological Institute (FMI) open data

| Item | Value |
| --- | --- |
| Docs | https://en.ilmatieteenlaitos.fi/open-data-manual |
| Base URL | `https://opendata.fmi.fi/wfs` (WFS 2.0, https works) |
| Auth | None; users must accept the open data licence |
| Query | Stored query `fmi::observations::weather::timevaluepair` with `fmisid`, `parameters=t2m,ws_10min`, `starttime`, `endtime` and **`timestep=10`** |
| Limits | At most **168 hours** per query; a longer range returns HTTP 400 with an `ExceptionReport` ("Too long time interval requested"). 20,000 requests / day and 600 / 5 minutes (FMI WFS services manual); the client sends at most one per second |
| Stations | Airports near population centres and the western wind power clusters, verified against the API: Helsinki-Vantaa **100968**, Oulu **101786**, Vaasa **101462**, Pori **101044** |

Quirks:
- **Without `timestep=10` the query returns 1-minute data**: about ten times the points and the response
  size (one station, two parameters, 7 days: 20,162 points and 6.5 MB versus 2,018 points and 0.66 MB).
- `starttime` and `endtime` are both **inclusive**: one hour returns 7 ten-minute points per parameter.
  Consecutive windows therefore share a boundary point; downstream dedupes.
- Missing values appear as `NaN`. Station metadata can change (handled as SCD2 in dbt).

## Ingestion rules (all sources)

- Fetch a window of **now − 48 h → now** every run, so late and revised data is picked up. Downstream dedupes.
- Write the raw response unchanged. Never transform in the Function.
- Backfill script loads history from **2024-01-01** so both 60- and 15-minute price grains are present.
  Chunk sizes follow the limits above: ENTSO-E at most one year, FMI at most 168 hours per request.
- Log source, dataset, window, row count and HTTP status for every call.
