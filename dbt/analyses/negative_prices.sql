-- Report question 2: when does the price go negative, and what do those intervals have in common?
-- Negative-price intervals against zero and positive ones: how often, when (local hour, weekend,
-- month), and with how much wind and consumption.
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
        facts.price_eur_mwh,
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
        count(*) as intervals,
        round(count(*) / sum(count(*)) over () * 100, 2) as share_of_intervals_pct,
        round(avg(price_eur_mwh), 2) as avg_price_eur_mwh,
        round(avg(wind_production_mw)) as avg_wind_mw,
        round(avg(consumption_mw)) as avg_consumption_mw,
        round(avg(wind_share_of_consumption) * 100, 1) as avg_wind_share_pct,
        round(avg(cast(is_weekend as int)) * 100, 1) as weekend_pct,
        mode(hour_of_day) as most_common_local_hour,
        mode(month_number) as most_common_month
    from joined
    group by price_band
)

select * from final
order by avg_price_eur_mwh
