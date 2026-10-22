with

prices as (
    select * from {{ ref('stg_entsoe__day_ahead_price') }}
),

periods as (
    select distinct
        period_start_utc,
        period_end_utc,
        resolution_minutes
    from prices
),

-- Every position the period should have: a delivery day is 23, 24 or 25 hours, so its length (not
-- a fixed 24 or 96) decides how many positions there are.
positions as (
    select
        period_start_utc,
        period_end_utc,
        resolution_minutes,
        explode(
            sequence(
                1,
                cast(
                    timestampdiff(minute, period_start_utc, period_end_utc) / resolution_minutes
                    as int
                )
            )
        ) as point_position
    from periods
),

-- Curve type A03 omits a position when its price repeats the previous one. Position 1 is never
-- omitted, so the last published price always exists.
filled as (
    select
        positions.period_start_utc,
        positions.period_end_utc,
        positions.resolution_minutes,
        positions.point_position,
        last_value(prices.price_eur_mwh) ignore nulls over (
            partition by positions.period_start_utc, positions.resolution_minutes
            order by positions.point_position
            rows between unbounded preceding and current row
        ) as price_eur_mwh,
        prices.price_eur_mwh is null as is_price_filled
    from positions
    left join prices
        on
            positions.period_start_utc = prices.period_start_utc
            and positions.resolution_minutes = prices.resolution_minutes
            and positions.point_position = prices.point_position
),

-- A 60-minute price applies to each of its four quarter-hours (ADR 0005); a 15-minute price to one.
quarters as (
    select
        *,
        explode(sequence(0, resolution_minutes - 15, 15)) as quarter_offset_minutes
    from filled
),

expanded as (
    select
        timestampadd(
            minute,
            (point_position - 1) * resolution_minutes + quarter_offset_minutes,
            period_start_utc
        ) as interval_start_utc,
        price_eur_mwh,
        resolution_minutes as price_resolution_minutes,
        is_price_filled,
        period_start_utc,
        period_end_utc
    from quarters
),

-- No delivery day has had both grains (phase 3 spec, step 0 item 6); if one ever does, the
-- 15-minute price is the more precise one.
final as (
    select * from expanded
    qualify
        row_number() over (
            partition by interval_start_utc
            order by price_resolution_minutes
        ) = 1
)

select * from final
