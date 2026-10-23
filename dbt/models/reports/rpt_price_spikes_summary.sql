-- Price-spike anatomy: the most expensive 1 % of intervals and the negative ones against all the
-- others. Net import is consumption minus production (positive: Finland imports).
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null
),

weather as (
    select * from {{ ref('fct_weather_15min') }}
),

dates as (
    select * from {{ ref('dim_date') }}
),

times as (
    select * from {{ ref('dim_time_15min') }}
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

classified as (
    select
        case
            when facts.price_eur_mwh >= threshold.top_1_pct_threshold_eur_mwh then 'top_1_pct'
            when facts.price_eur_mwh < 0 then 'negative'
            else 'other'
        end as spike_class,
        threshold.top_1_pct_threshold_eur_mwh,
        cast(facts.price_eur_mwh as double) as price_eur_mwh,
        facts.wind_production_mw,
        facts.consumption_mw,
        facts.production_mw,
        facts.consumption_mw - facts.production_mw as net_import_mw,
        national_temperature.temperature_c,
        dates.is_weekend,
        dates.month_number,
        times.hour_of_day
    from facts
    cross join threshold
    left join national_temperature
        on facts.interval_start_utc = national_temperature.interval_start_utc
    inner join dates on facts.date_key = dates.date_key
    inner join times on facts.time_key = times.time_key
),

final as (
    select
        spike_class,
        any_value(top_1_pct_threshold_eur_mwh) as top_1_pct_threshold_eur_mwh,
        count(*) as interval_count,
        avg(price_eur_mwh) as avg_price_eur_mwh,
        avg(wind_production_mw) as avg_wind_production_mw,
        avg(consumption_mw) as avg_consumption_mw,
        avg(production_mw) as avg_production_mw,
        avg(net_import_mw) as avg_net_import_mw,
        avg(temperature_c) as avg_temperature_c,
        avg(cast(is_weekend as int)) as weekend_share,
        mode(hour_of_day) as most_common_local_hour,
        mode(month_number) as most_common_month
    from classified
    group by spike_class
)

select * from final
