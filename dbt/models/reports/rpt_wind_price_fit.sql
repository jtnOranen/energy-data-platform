-- Report question 1: how much of the price variation does wind production explain? A simple
-- linear fit of price on wind per year and price grain; for one predictor, r² is the share of the
-- price variance the fit explains. Intervals missing either value are left out.
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
        cast(facts.price_eur_mwh as double) as price_eur_mwh,
        facts.wind_production_mw
    from facts
    inner join dates on facts.date_key = dates.date_key
),

final as (
    select
        year_number,
        price_resolution_minutes,
        count(*) as interval_count,
        corr(wind_production_mw, price_eur_mwh) as correlation,
        power(corr(wind_production_mw, price_eur_mwh), 2) as r_squared,
        -- EUR/MWh per additional GW of wind.
        regr_slope(price_eur_mwh, wind_production_mw) * 1000 as slope_eur_mwh_per_gw,
        regr_intercept(price_eur_mwh, wind_production_mw) as price_at_zero_wind_eur_mwh
    from joined
    group by year_number, price_resolution_minutes
)

select * from final
