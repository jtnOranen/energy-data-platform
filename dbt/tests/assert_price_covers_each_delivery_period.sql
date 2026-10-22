-- Every delivery period yields one price per quarter-hour of its real length: 92 on the spring DST
-- day, 100 on the autumn one, 96 otherwise. Returns the periods that don't.
with

prices as (
    select * from {{ ref('int_price_15min') }}
),

final as (
    select
        period_start_utc,
        period_end_utc,
        count(*) as quarter_hours,
        timestampdiff(minute, period_start_utc, period_end_utc) / 15 as expected_quarter_hours
    from prices
    group by period_start_utc, period_end_utc
    having count(*) != timestampdiff(minute, period_start_utc, period_end_utc) / 15
)

select * from final
