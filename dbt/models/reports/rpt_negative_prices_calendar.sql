-- Report question 2, the heatmap: when negative prices happen, per local month and hour of day.
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
        make_date(dates.year_number, dates.month_number, 1) as month_start,
        times.hour_of_day,
        facts.price_eur_mwh < 0 as is_negative
    from facts
    inner join dates on facts.date_key = dates.date_key
    inner join times on facts.time_key = times.time_key
),

final as (
    select
        month_start,
        hour_of_day,
        count(*) as interval_count,
        count_if(is_negative) as negative_interval_count,
        cast(count_if(is_negative) / count(*) as double) as negative_share
    from joined
    group by month_start, hour_of_day
)

select * from final
