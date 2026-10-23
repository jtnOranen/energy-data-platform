-- Report question 2: what do negative-price intervals have in common? Negative, zero and positive
-- prices side by side: how often, with how much wind and consumption, and when (local time).
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
        case
            when facts.price_eur_mwh < 0 then 'negative'
            when facts.price_eur_mwh = 0 then 'zero'
            else 'positive'
        end as price_band,
        cast(facts.price_eur_mwh as double) as price_eur_mwh,
        facts.wind_production_mw,
        facts.consumption_mw,
        facts.wind_production_mw / nullif(facts.consumption_mw, 0) as wind_share_of_consumption,
        dates.is_weekend,
        dates.month_number,
        times.hour_of_day
    from facts
    inner join dates on facts.date_key = dates.date_key
    inner join times on facts.time_key = times.time_key
),

final as (
    select
        price_band,
        count(*) as interval_count,
        cast(count(*) / sum(count(*)) over () as double) as share_of_intervals,
        avg(price_eur_mwh) as avg_price_eur_mwh,
        avg(wind_production_mw) as avg_wind_production_mw,
        avg(consumption_mw) as avg_consumption_mw,
        avg(wind_share_of_consumption) as avg_wind_share_of_consumption,
        avg(cast(is_weekend as int)) as weekend_share,
        mode(hour_of_day) as most_common_local_hour,
        mode(month_number) as most_common_month
    from joined
    group by price_band
)

select * from final
