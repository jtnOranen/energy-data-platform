-- Report question 4b: did 15-minute pricing change intra-hour variation?
-- Before 2025-10-01 the four quarter-hours of an hour share one price by construction, so their
-- spread is zero. The fair comparison is how much the price moves: the spread within the hour
-- (15-minute era only) and the change from one hour's average to the next (both eras).
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null
),

hours as (
    select
        date_trunc('hour', interval_start_utc) as hour_start_utc,
        min(price_resolution_minutes) as price_resolution_minutes,
        max(price_eur_mwh) - min(price_eur_mwh) as intra_hour_spread,
        avg(price_eur_mwh) as hourly_avg_price
    from facts
    group by date_trunc('hour', interval_start_utc)
),

with_previous as (
    select
        *,
        abs(
            hourly_avg_price - lag(hourly_avg_price) over (order by hour_start_utc)
        ) as change_from_previous_hour
    from hours
),

final as (
    select
        price_resolution_minutes,
        count(*) as hour_count,
        round(avg(intra_hour_spread), 2) as avg_intra_hour_spread,
        round(percentile(intra_hour_spread, 0.95), 2) as p95_intra_hour_spread,
        round(avg(change_from_previous_hour), 2) as avg_hour_to_hour_change,
        round(percentile(change_from_previous_hour, 0.95), 2) as p95_hour_to_hour_change
    from with_previous
    group by price_resolution_minutes
)

select * from final
order by price_resolution_minutes desc
