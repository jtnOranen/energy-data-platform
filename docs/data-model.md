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
| `int_price_15min` | 15 min | Every position of each delivery period generated from the period length (23/24/25 h); omitted A03 positions forward-filled (`is_price_filled`); then 60-min prices expanded to four 15-min rows, 15-min prices as is; the 15-min price wins if both exist |
| `int_power_15min` | 15 min | The three Fingrid datasets combined on interval start, null where one has a gap; records longer than 15 min split into quarter-hours with the same average power |
| `int_weather_15min` | station × 15 min | Average of the 10-min observations with `interval_start ≤ observed_at < interval_start + 15 min` (two, then one, in turn); `NaN`s ignored; `observation_count` |

## Gold (dbt, `models/marts`) — star schema

| Model | Type | Grain / key |
| --- | --- | --- |
| `fct_power_15min` | fact, incremental (merge), built from a 15-min time spine | `interval_start_utc` |
| `fct_weather_15min` | fact, incremental (merge) | `interval_start_utc`, `weather_station_key` |
| `dim_date` | dimension, 2024-01-01 to 2030-12-31 | `date_key` (yyyymmdd, local Finnish date, for reporting) |
| `dim_time_15min` | dimension | 96 rows, `time_key` (local hhmm) |
| `dim_weather_station` | SCD2 from `snapshots/weather_station_snapshot` over the `weather_stations` seed | `weather_station_key`, `valid_from`, `valid_to`, `is_current` |

Measures in `fct_power_15min`: `price_eur_mwh`, `price_resolution_minutes`, `wind_production_mw`, `consumption_mw`,
`production_mw`. In `fct_weather_15min`: `temperature_c`, `wind_speed_ms`, `observation_count`. Both facts carry
`date_key` and `time_key` from the interval start in `Europe/Helsinki`; on the autumn DST day two intervals share
a `time_key`. Each incremental run rebuilds the last 3 days (`lookback_days`). The first version of each station
is valid from 1900-01-01, so observations older than the snapshot find a version.

Gold models have **model contracts** (`contract: {enforced: true}`) with named primary and foreign key
constraints. Unity Catalog records those keys but doesn't enforce them; the `unique` and `relationships` tests do.

## Reports (dbt, `models/reports`, in gold)

Tested tables the `energy_report` dashboard selects from (phase 5, decision 1), recorded as a dbt exposure. Local
time comes from the dimensions; contracts enforced.

| Model | Grain | Answers |
| --- | --- | --- |
| `rpt_wind_price_fit` | year × price grain | Q1: correlation, r², slope per GW, price at zero wind |
| `rpt_wind_price_bands` | year × price grain × 500 MW wind band | Q1 chart: average, median, 10th/90th percentile price |
| `rpt_negative_prices_summary` | price band (negative / zero / positive) | Q2: share, wind, consumption, weekend share, typical hour and month |
| `rpt_negative_prices_calendar` | local month × hour | Q2 heatmap: share of negative quarter-hours |
| `rpt_winter_consumption_temperature` | winter × 2 °C band | Q3: consumption by temperature, each winter's fit |
| `rpt_price_profiles` | day type × local hour | Q4a: average price, relative to the day type's average |
| `rpt_intra_hour_spread` | price grain × local hour | Q4b: spread within the hour, change from the previous hour |
| `rpt_price_spikes_summary` | spike class (top 1 % / negative / other) | price-spike anatomy |
| `rpt_price_spike_intervals` | quarter-hour in the top 1 % | the spikes, ranked, with the system's state |

## Tests

| Where | Test |
| --- | --- |
| sources | `freshness` on bronze (bronze loads every 6 hours, so e.g. warn 8 h, error 24 h — tune after observing) |
| staging | `unique` + `not_null` on natural keys |
| staging (ENTSO-E) | `accepted_values` on zone, currency, unit, curve type, resolution |
| intermediate | dbt **unit tests**: 60→15 min expansion, A03 forward-fill, 15-min preference, long Fingrid records, weather alignment; data test: every delivery period (DST days included) yields one price per quarter-hour |
| `fct_power_15min` | `unique` + `not_null` on `interval_start_utc`; `relationships` to dims; custom test: every complete UTC day has exactly 96 rows (the fact is built from a 15-min time spine, because Fingrid has gaps; measures may be null) |
| `fct_weather_15min` | unique (`interval_start_utc`, `weather_station_key`); `relationships` to dims; temperature and wind speed ranges (warn) |
| `dim_weather_station` | one current row per station |
| prices | `price_eur_mwh` within the SDAC clearing price limits (vars, warn; negative prices are valid) |
