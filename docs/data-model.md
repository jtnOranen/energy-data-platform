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
| `bronze.entsoe_day_ahead_price` | parsed XML points with `period_start`, `resolution`, `position`, `price` |
| `bronze.fmi_observations` | station, parameter, time, value |

Every bronze table has `_ingested_at` and `_source_file`. Duplicates are expected (overlapping fetch windows).

## Silver (dbt, `models/staging` + `models/intermediate`)

| Model | Grain | Logic |
| --- | --- | --- |
| `stg_fingrid__wind_production` | source timestamp | typed, deduped on (dataset, start_time) keeping latest `_ingested_at` |
| `stg_entsoe__day_ahead_price` | source interval | interval start/end computed from period start, resolution and position |
| `stg_fmi__observations` | station × parameter × 10 min | `NaN` → null |
| `int_price_15min` | 15 min | 60-min prices expanded to four 15-min rows; 15-min prices as is |
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
| sources | `freshness` (warn 3 h, error 12 h — tune after observing) |
| staging | `unique` + `not_null` on natural keys |
| intermediate | dbt **unit tests**: 60→15 min expansion; DST transition days |
| `fct_power_15min` | `unique` + `not_null` on `interval_start_utc`; `relationships` to dims; custom test: every complete UTC day has exactly 96 rows |
| `dim_weather_station` | one current row per station |
| prices | `price_eur_mwh` within a sane range (negative prices are valid) |
