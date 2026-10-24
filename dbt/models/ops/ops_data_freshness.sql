-- How fresh the data is at each layer: the newest fetch in each bronze table, and the newest
-- quarter-hour with each measure in gold. A view, so "hours since" is measured when the dashboard
-- is opened.
with

power as (
    select * from {{ ref('fct_power_15min') }}
),

weather as (
    select * from {{ ref('fct_weather_15min') }}
),

bronze as (
    select
        'fingrid_wind_production' as relation_name,
        max(_ingested_at) as newest_data_utc,
        max(_loaded_at) as last_loaded_utc
    from {{ source('bronze', 'fingrid_wind_production') }}
    union all
    select
        'fingrid_consumption' as relation_name,
        max(_ingested_at) as newest_data_utc,
        max(_loaded_at) as last_loaded_utc
    from {{ source('bronze', 'fingrid_consumption') }}
    union all
    select
        'fingrid_production' as relation_name,
        max(_ingested_at) as newest_data_utc,
        max(_loaded_at) as last_loaded_utc
    from {{ source('bronze', 'fingrid_production') }}
    union all
    select
        'entsoe_day_ahead_price' as relation_name,
        max(_ingested_at) as newest_data_utc,
        max(_loaded_at) as last_loaded_utc
    from {{ source('bronze', 'entsoe_day_ahead_price') }}
    union all
    select
        'fmi_observations' as relation_name,
        max(_ingested_at) as newest_data_utc,
        max(_loaded_at) as last_loaded_utc
    from {{ source('bronze', 'fmi_observations') }}
),

gold as (
    select
        'fct_power_15min (price)' as relation_name,
        max(interval_start_utc) as newest_data_utc
    from power
    where price_eur_mwh is not null
    union all
    select
        'fct_power_15min (power)' as relation_name,
        max(interval_start_utc) as newest_data_utc
    from power
    where wind_production_mw is not null
    union all
    select
        'fct_weather_15min' as relation_name,
        max(interval_start_utc) as newest_data_utc
    from weather
),

layers as (
    select
        'bronze' as layer,
        relation_name,
        newest_data_utc,
        last_loaded_utc
    from bronze
    union all
    select
        'gold' as layer,
        relation_name,
        newest_data_utc,
        cast(null as timestamp) as last_loaded_utc
    from gold
),

final as (
    select
        layer,
        relation_name,
        newest_data_utc,
        last_loaded_utc,
        timestampdiff(minute, newest_data_utc, current_timestamp()) / 60.0
            as hours_since_newest_data
    from layers
)

select * from final
