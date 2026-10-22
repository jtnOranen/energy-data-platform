{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['interval_start_utc', 'weather_station_key'],
        on_schema_change='fail'
    )
}}

with

weather as (
    select * from {{ ref('int_weather_15min') }}
    {% if is_incremental() -%}
        -- Rebuild the last lookback_days, like fct_power_15min.
        where
            interval_start_utc >= (
                select
                    timestampadd(
                        day, -{{ var('lookback_days') }}, max(interval_start_utc)
                    )
                from {{ this }}
            )
    {%- endif %}
),

stations as (
    select * from {{ ref('dim_weather_station') }}
),

-- FMI has no gaps (phase 3 spec, step 0 item 6), so unlike the power fact this one needs no
-- time spine. Each observation points to the station version valid at its time.
final as (
    select
        weather.interval_start_utc,
        stations.weather_station_key,
        {{ local_date_key('weather.interval_start_utc') }} as date_key,
        {{ local_time_key('weather.interval_start_utc') }} as time_key,
        weather.temperature_c,
        weather.wind_speed_ms,
        weather.observation_count
    from weather
    inner join stations
        on
            weather.fmisid = stations.fmisid
            and weather.interval_start_utc >= stations.valid_from
            and weather.interval_start_utc < stations.valid_to
)

select * from final
