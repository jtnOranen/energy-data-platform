# Data model

Unity Catalog catalog `energy`, schemas `bronze`, `silver`, `gold`. All timestamps are UTC (`timestamp` type,
column suffix `_utc`). Grain of the analytical model: **one row per 15-minute interval**.

## Bronze (Auto Loader, PySpark)

One table per source dataset, raw structure plus metadata.

| Table | Content |
| --- | --- |
| `bronze.fingrid_wind_production` | raw Fingrid records (dataset 75, 15 min) |
| `bronze.fingrid_consumption` | raw Fingrid records (dataset 124, 15 min) |
| `bronze.fingrid_production` | raw Fingrid records (dataset 74, 15 min) |
| `bronze.entsoe_day_ahead_price` | one row per XML `Point`: `document_mrid`, `revision_number`, `time_series_mrid`, `in_domain`, `currency_unit`, `price_measure_unit`, `curve_type`, `period_start`, `period_end`, `resolution`, `position`, `price_amount` |
| `bronze.fmi_observations` | one row per time-value pair: `fmisid`, `parameter`, `time`, `value` |

All bronze columns are strings, exactly as the source sent them; staging types them. Every bronze table
has `_ingested_at` (fetch time from the file name), `_source_file`, `_loaded_at` and `_rescued_data`.
Duplicates are expected (overlapping fetch windows).

## Silver (dbt, `models/staging` + `models/intermediate`)

| Model | Grain | Logic |
| --- | --- | --- |
| `stg_fingrid__wind_production`, `stg_fingrid__consumption`, `stg_fingrid__production` | `interval_start_utc` | typed, deduped keeping the latest `_ingested_at` (the newest interval of a fetch is often revised by the next one) |
| `stg_entsoe__day_ahead_price` | `interval_start_utc`, `resolution_minutes` | the latest fetch of each delivery period, chosen as a whole (highest revision, then latest `_ingested_at`); `interval_start_utc` = period start + (position − 1) × resolution; omitted A03 positions still missing |
| `stg_fmi__observations` | `fmisid`, `parameter`, `observed_at_utc` | `NaN` → null; deduped keeping the latest `_ingested_at` |
| `int_price_15min` | 15 min | Omitted A03 positions forward-filled within each period first (about a third of periods have gaps); then 60-min prices expanded to four 15-min rows, 15-min prices as is |
| `int_power_15min` | 15 min | Fingrid 15-min values joined on interval start (timestamps aligned to the interval start, see `docs/data-sources.md`); no averaging needed |
| `int_weather_15min` | station × 15 min | 10-min values aligned to 15-min intervals (document the rule) |

## Gold (dbt, `models/marts`) — star schema

| Model | Type | Grain / key |
| --- | --- | --- |
| `fct_power_15min` | fact, incremental (merge) | `interval_start_utc` (+ `weather_station_key` for weather measures if kept here, or a separate fact) |
| `fct_weather_15min` | fact, incremental (merge) | `interval_start_utc`, `weather_station_key` |
| `dim_date` | dimension | `date_key` (local Finnish date, for reporting) |
| `dim_time_15min` | dimension | 96 rows, `time_key` |
| `dim_weather_station` | SCD2 from `snapshots/weather_station_snapshot` | `weather_station_key`, `valid_from`, `valid_to` |

Measures in `fct_power_15min`: `price_eur_mwh`, `price_resolution_minutes`, `wind_production_mw`, `consumption_mw`.

Gold models have **model contracts** (`contract: {enforced: true}`).

## Tests

| Where | Test |
| --- | --- |
| sources | `freshness` on bronze (bronze loads every 6 hours, so e.g. warn 8 h, error 24 h — tune after observing) |
| staging | `unique` + `not_null` on natural keys |
| intermediate | dbt **unit tests**: 60→15 min expansion; DST transition days |
| `fct_power_15min` | `unique` + `not_null` on `interval_start_utc`; `relationships` to dims; custom test: every complete UTC day has exactly 96 rows (the fact is built from a 15-min time spine, because Fingrid has gaps; measures may be null) |
| `dim_weather_station` | one current row per station |
| prices | `price_eur_mwh` within a sane range (negative prices are valid) |
