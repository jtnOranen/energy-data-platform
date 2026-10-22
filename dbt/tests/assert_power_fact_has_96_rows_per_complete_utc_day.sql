-- Every complete UTC day has exactly 96 rows in the power fact (ADR 0005); the fact is built from a
-- time spine, so this holds even where Fingrid has gaps. The last day is still filling, so it is
-- left out. Returns the days that don't have 96 rows.
with

facts as (
    select * from {{ ref('fct_power_15min') }}
),

days as (
    select
        to_date(interval_start_utc) as interval_date,
        count(*) as interval_count
    from facts
    group by to_date(interval_start_utc)
),

last_day as (
    select max(interval_date) as interval_date from days
),

final as (
    select days.*
    from days
    cross join last_day
    where
        days.interval_count != 96
        and days.interval_date < last_day.interval_date
)

select * from final
