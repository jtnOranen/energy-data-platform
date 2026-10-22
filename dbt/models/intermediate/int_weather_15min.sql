with

observations as (
    select * from {{ ref('stg_fmi__observations') }}
),

-- Each 10-minute observation belongs to the quarter-hour it falls in (start inclusive), so the
-- quarter-hours get two, one, two, one observations in turn: :00 and :10, :20, :30 and :40, :50.
aligned as (
    select
        fmisid,
        parameter,
        observed_at_utc,
        observation_value,
        timestamp_seconds(floor(unix_seconds(observed_at_utc) / 900) * 900) as interval_start_utc
    from observations
),

-- avg ignores nulls, so a missing (NaN) observation doesn't pull the average down.
final as (
    select
        fmisid,
        interval_start_utc,
        avg(case when parameter = 't2m' then observation_value end) as temperature_c,
        avg(case when parameter = 'ws_10min' then observation_value end) as wind_speed_ms,
        count(distinct observed_at_utc) as observation_count
    from aligned
    group by fmisid, interval_start_utc
)

select * from final
