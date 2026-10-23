-- Report question 4b: did 15-minute pricing change intra-hour variation? Per price grain and local
-- hour: the spread of the four quarter-hour prices within an hour (zero by construction before
-- 2025-10-01) and the change from one hour's average to the next, which works for both eras.
with

facts as (
    select * from {{ ref('fct_power_15min') }}
    where price_eur_mwh is not null
),

hours as (
    select
        date_trunc('hour', interval_start_utc) as hour_start_utc,
        min(price_resolution_minutes) as price_resolution_minutes,
        cast(max(price_eur_mwh) - min(price_eur_mwh) as double) as intra_hour_spread,
        cast(avg(price_eur_mwh) as double) as hourly_avg_price
    from facts
    group by date_trunc('hour', interval_start_utc)
),

with_previous as (
    select
        price_resolution_minutes,
        -- Local hour, the same rule as the facts' time_key (macros/local_time_keys.sql).
        hour(from_utc_timestamp(hour_start_utc, 'Europe/Helsinki')) as hour_of_day,
        intra_hour_spread,
        abs(hourly_avg_price - lag(hourly_avg_price) over (order by hour_start_utc))
            as change_from_previous_hour
    from hours
),

final as (
    select
        price_resolution_minutes,
        hour_of_day,
        count(*) as hour_count,
        avg(intra_hour_spread) as avg_intra_hour_spread,
        percentile(intra_hour_spread, 0.95) as p95_intra_hour_spread,
        avg(change_from_previous_hour) as avg_change_from_previous_hour,
        percentile(change_from_previous_hour, 0.95) as p95_change_from_previous_hour
    from with_previous
    group by price_resolution_minutes, hour_of_day
)

select * from final
