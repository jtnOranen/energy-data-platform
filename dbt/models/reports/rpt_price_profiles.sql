-- Report question 4a: the daily and weekly price profiles. Average price per local hour on
-- weekdays and at weekends, and each hour relative to its day type's average.
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null
),

dates as (
    select * from {{ ref('dim_date') }}
),

times as (
    select * from {{ ref('dim_time_15min') }}
),

joined as (
    select
        case when dates.is_weekend then 'weekend' else 'weekday' end as day_type,
        times.hour_of_day,
        cast(facts.price_eur_mwh as double) as price_eur_mwh
    from facts
    inner join dates on facts.date_key = dates.date_key
    inner join times on facts.time_key = times.time_key
),

hourly as (
    select
        day_type,
        hour_of_day,
        count(*) as interval_count,
        avg(price_eur_mwh) as avg_price_eur_mwh
    from joined
    group by day_type, hour_of_day
),

final as (
    select
        day_type,
        hour_of_day,
        interval_count,
        avg_price_eur_mwh,
        avg_price_eur_mwh / avg(avg_price_eur_mwh) over (partition by day_type)
            as relative_to_day_type_average
    from hourly
)

select * from final
