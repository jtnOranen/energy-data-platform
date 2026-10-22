with

-- A record longer than 15 minutes (a few in the history) is split into quarter-hours with the same
-- value: the value is average power, which holds for each part.
wind_production as (
    select
        explode(
            sequence(
                interval_start_utc,
                interval_end_utc - interval 15 minutes,
                interval 15 minutes
            )
        ) as interval_start_utc,
        wind_production_mw
    from {{ ref('stg_fingrid__wind_production') }}
),

consumption as (
    select
        explode(
            sequence(
                interval_start_utc,
                interval_end_utc - interval 15 minutes,
                interval 15 minutes
            )
        ) as interval_start_utc,
        consumption_mw
    from {{ ref('stg_fingrid__consumption') }}
),

production as (
    select
        explode(
            sequence(
                interval_start_utc,
                interval_end_utc - interval 15 minutes,
                interval 15 minutes
            )
        ) as interval_start_utc,
        production_mw
    from {{ ref('stg_fingrid__production') }}
),

-- One row per interval that any dataset has; a dataset with a gap leaves its column null.
unioned as (
    select
        interval_start_utc,
        wind_production_mw,
        cast(null as double) as consumption_mw,
        cast(null as double) as production_mw
    from wind_production

    union all

    select
        interval_start_utc,
        cast(null as double) as wind_production_mw,
        consumption_mw,
        cast(null as double) as production_mw
    from consumption

    union all

    select
        interval_start_utc,
        cast(null as double) as wind_production_mw,
        cast(null as double) as consumption_mw,
        production_mw
    from production
),

final as (
    select
        interval_start_utc,
        max(wind_production_mw) as wind_production_mw,
        max(consumption_mw) as consumption_mw,
        max(production_mw) as production_mw
    from unioned
    group by interval_start_utc
)

select * from final
