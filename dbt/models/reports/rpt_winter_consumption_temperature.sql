-- Report question 3: how does consumption follow temperature in winter? Consumption per 2-degree
-- band of the four stations' average temperature, December to February (local months), per winter,
-- with each winter's linear fit (repeated on its rows, so a chart can show it).
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
        -- A winter is named after its two years, December belonging to the first: 2024-25.
        concat(
            dates.year_number - if(dates.month_number = 12, 0, 1),
            '-',
            lpad(
                cast((dates.year_number + if(dates.month_number = 12, 1, 0)) % 100 as string),
                2,
                '0'
            )
        ) as winter_label,
        national_temperature.temperature_c,
        power.consumption_mw
    from power
    inner join national_temperature
        on power.interval_start_utc = national_temperature.interval_start_utc
    inner join dates on power.date_key = dates.date_key
    where dates.month_number in (12, 1, 2) and national_temperature.temperature_c is not null
),

bands as (
    select
        winter_label,
        cast(floor(temperature_c / 2) * 2 as int) as temperature_band_c,
        count(*) as interval_count,
        avg(consumption_mw) as avg_consumption_mw
    from winter
    group by winter_label, cast(floor(temperature_c / 2) * 2 as int)
),

fit as (
    select
        winter_label,
        corr(temperature_c, consumption_mw) as winter_correlation,
        regr_slope(consumption_mw, temperature_c) as winter_slope_mw_per_degree
    from winter
    group by winter_label
),

final as (
    select
        bands.winter_label,
        bands.temperature_band_c,
        bands.interval_count,
        bands.avg_consumption_mw,
        fit.winter_correlation,
        fit.winter_slope_mw_per_degree
    from bands
    inner join fit on bands.winter_label = fit.winter_label
)

select * from final
