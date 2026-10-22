with

source as (
    select * from {{ source('bronze', 'fmi_observations') }}
),

typed as (
    select
        cast(fmisid as int) as fmisid,
        parameter,
        to_timestamp(time) as observed_at_utc,
        -- FMI sends missing values as NaN; casting 'NaN' would give a NaN double, not null.
        cast(nullif(value, 'NaN') as double) as observation_value,
        _ingested_at,
        _source_file
    from source
),

-- Consecutive fetch windows share their boundary point and overlap 48 hours; the latest fetch wins.
deduplicated as (
    select * from typed
    qualify
        row_number() over (
            partition by fmisid, parameter, observed_at_utc
            order by _ingested_at desc, _source_file desc
        ) = 1
),

final as (
    select
        fmisid,
        parameter,
        observed_at_utc,
        observation_value,
        _ingested_at
    from deduplicated
)

select * from final
