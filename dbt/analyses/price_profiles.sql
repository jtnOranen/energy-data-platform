-- Report question 4a: what do the daily and weekly price profiles look like?
-- Average price by local hour, on weekdays and at weekends, with each hour's price relative to the
-- day's average.
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
        facts.price_eur_mwh
    from facts
    inner join dates on facts.date_key = dates.date_key
    inner join times on facts.time_key = times.time_key
),

hourly as (
    select
        day_type,
        hour_of_day,
        avg(price_eur_mwh) as avg_price_eur_mwh
    from joined
    group by day_type, hour_of_day
),

final as (
    select
        day_type,
        hour_of_day,
        round(avg_price_eur_mwh, 2) as avg_price_eur_mwh,
        round(avg_price_eur_mwh / avg(avg_price_eur_mwh) over (partition by day_type), 2)
            as relative_to_daily_average
    from hourly
)

select * from final
order by day_type, hour_of_day
