-- One row per local Finnish date: the report asks about local days, weekdays and seasons. The
-- range is fixed so the dimension doesn't depend on what the facts contain yet. Month and day
-- names are English whatever the warehouse's locale (Spark's date_format); the report layer
-- translates them if it needs Finnish.
with

days as (
    select
        explode(
            sequence(
                to_date('{{ var("dim_date_start") }}'),
                to_date('{{ var("dim_date_end") }}'),
                interval 1 day
            )
        ) as date_day
),

final as (
    select
        cast(date_format(date_day, 'yyyyMMdd') as int) as date_key,
        date_day,
        year(date_day) as year_number,
        quarter(date_day) as quarter_number,
        month(date_day) as month_number,
        date_format(date_day, 'MMMM') as month_name,
        weekofyear(date_day) as iso_week_number,
        extract(dayofweek_iso from date_day) as iso_day_of_week,
        date_format(date_day, 'EEEE') as day_name,
        extract(dayofweek_iso from date_day) >= 6 as is_weekend,
        -- 92 on the spring DST day, 100 on the autumn one, 96 otherwise.
        cast(
            timestampdiff(
                minute,
                to_utc_timestamp(date_day, 'Europe/Helsinki'),
                to_utc_timestamp(date_add(date_day, 1), 'Europe/Helsinki')
            ) / 15 as int
        ) as intervals_in_day
    from days
)

select * from final
