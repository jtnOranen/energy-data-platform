-- Price-spike anatomy, the table: every interval in the most expensive 1 %, with what the system
-- looked like at the time, ranked by price.
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null
),

weather as (
    select * from {{ ref('fct_weather_15min') }}
),

threshold as (
    select percentile(cast(price_eur_mwh as double), 0.99) as top_1_pct_threshold_eur_mwh
    from facts
),

national_temperature as (
    select
        interval_start_utc,
        avg(temperature_c) as temperature_c
    from weather
    group by interval_start_utc
),

spikes as (
    select facts.*
    from facts
    cross join threshold
    where facts.price_eur_mwh >= threshold.top_1_pct_threshold_eur_mwh
),

final as (
    select
        cast(
            row_number() over (
                order by spikes.price_eur_mwh desc, spikes.interval_start_utc asc
            ) as int
        ) as price_rank,
        spikes.interval_start_utc,
        -- Wall-clock time in Finland, for reading; the report layer is where local time belongs.
        from_utc_timestamp(spikes.interval_start_utc, 'Europe/Helsinki') as interval_start_local,
        spikes.price_eur_mwh,
        spikes.price_resolution_minutes,
        spikes.wind_production_mw,
        spikes.consumption_mw,
        spikes.production_mw,
        spikes.consumption_mw - spikes.production_mw as net_import_mw,
        national_temperature.temperature_c
    from spikes
    left join national_temperature
        on spikes.interval_start_utc = national_temperature.interval_start_utc
)

select * from final
