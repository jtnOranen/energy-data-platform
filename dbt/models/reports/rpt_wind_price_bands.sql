-- Report question 1, the chart: the price distribution per 500 MW band of wind production, per
-- year and price grain. Median and the 10th/90th percentiles show the spread, not just the mean.
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null and wind_production_mw is not null
),

dates as (
    select * from {{ ref('dim_date') }}
),

joined as (
    select
        dates.year_number,
        facts.price_resolution_minutes,
        cast(floor(facts.wind_production_mw / 500) * 500 as int) as wind_band_mw,
        cast(facts.price_eur_mwh as double) as price_eur_mwh
    from facts
    inner join dates on facts.date_key = dates.date_key
),

final as (
    select
        year_number,
        price_resolution_minutes,
        wind_band_mw,
        count(*) as interval_count,
        avg(price_eur_mwh) as avg_price_eur_mwh,
        percentile(price_eur_mwh, 0.1) as p10_price_eur_mwh,
        percentile(price_eur_mwh, 0.5) as median_price_eur_mwh,
        percentile(price_eur_mwh, 0.9) as p90_price_eur_mwh
    from joined
    group by year_number, price_resolution_minutes, wind_band_mw
)

select * from final
