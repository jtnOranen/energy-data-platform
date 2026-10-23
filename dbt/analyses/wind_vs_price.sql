-- Report question 1: how much of the price variation does wind production explain?
-- A simple linear fit of price on wind per year and price grain. For one predictor, r² is the
-- share of the price variance the fit explains (corr²). Intervals missing either value are left
-- out.
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
        facts.price_eur_mwh,
        facts.wind_production_mw
    from facts
    inner join dates on facts.date_key = dates.date_key
),

final as (
    select
        year_number,
        price_resolution_minutes,
        count(*) as intervals,
        round(corr(wind_production_mw, price_eur_mwh), 3) as correlation,
        round(power(corr(wind_production_mw, price_eur_mwh), 2), 3) as r_squared,
        -- EUR/MWh change per additional GW of wind.
        round(regr_slope(price_eur_mwh, wind_production_mw) * 1000, 2) as slope_eur_mwh_per_gw,
        round(regr_intercept(price_eur_mwh, wind_production_mw), 2) as price_at_zero_wind
    from joined
    group by year_number, price_resolution_minutes
)

select * from final
order by year_number asc, price_resolution_minutes desc
