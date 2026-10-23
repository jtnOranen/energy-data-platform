-- Report question 3: how does consumption follow temperature in winter?
-- Winter (December-February) consumption against the average temperature of the four stations, in
-- 5-degree bands. The slope is the average change in consumption per degree.
with

power as (
    select * from {{ ref('fct_power_15min') }}
    where consumption_mw is not null
),

weather as (
    select * from {{ ref('fct_weather_15min') }}
),

dates as (
    select * from {{ ref('dim_date') }}
),

national_temperature as (
    select
        interval_start_utc,
        avg(temperature_c) as temperature_c
    from weather
    group by interval_start_utc
),

winter as (
    select
        power.consumption_mw,
        national_temperature.temperature_c
    from power
    inner join national_temperature
        on power.interval_start_utc = national_temperature.interval_start_utc
    inner join dates on power.date_key = dates.date_key
    where dates.month_number in (12, 1, 2) and national_temperature.temperature_c is not null
),

bands as (
    select
        cast(floor(temperature_c / 5) * 5 as int) as temperature_band_c,
        count(*) as intervals,
        round(avg(consumption_mw)) as avg_consumption_mw
    from winter
    group by cast(floor(temperature_c / 5) * 5 as int)
),

fit as (
    select
        round(corr(temperature_c, consumption_mw), 3) as correlation,
        round(regr_slope(consumption_mw, temperature_c)) as slope_mw_per_degree
    from winter
),

final as (
    select
        bands.temperature_band_c,
        bands.intervals,
        bands.avg_consumption_mw,
        fit.correlation,
        fit.slope_mw_per_degree
    from bands
    cross join fit
)

select * from final
order by temperature_band_c
