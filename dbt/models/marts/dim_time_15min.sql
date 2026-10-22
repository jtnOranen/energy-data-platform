-- The 96 quarter-hours of a local day, for hour-of-day profiles. time_key is hhmm (e.g. 1345).
with

quarter_hours as (
    select explode(sequence(0, 95)) as quarter_hour_of_day
),

final as (
    select
        cast(floor(quarter_hour_of_day / 4) * 100 + (quarter_hour_of_day % 4) * 15 as int)
            as time_key,
        cast(floor(quarter_hour_of_day / 4) as int) as hour_of_day,
        cast((quarter_hour_of_day % 4) * 15 as int) as minute_of_hour,
        cast(quarter_hour_of_day % 4 + 1 as int) as quarter_of_hour,
        concat(
            lpad(cast(floor(quarter_hour_of_day / 4) as string), 2, '0'),
            ':',
            lpad(cast((quarter_hour_of_day % 4) * 15 as string), 2, '0')
        ) as time_label
    from quarter_hours
)

select * from final
