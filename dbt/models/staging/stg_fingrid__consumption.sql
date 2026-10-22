with

source as (
    select * from {{ source('bronze', 'fingrid_consumption') }}
),

typed as (
    select
        to_timestamp(starttime) as interval_start_utc,
        to_timestamp(endtime) as interval_end_utc,
        cast(value as double) as consumption_mw,
        _ingested_at,
        _source_file
    from source
),

-- Every fetch overlaps the previous 48 hours, and the newest interval of a fetch can be revised
-- in the next one, so the latest fetch wins.
deduplicated as (
    select * from typed
    qualify
        row_number() over (
            partition by interval_start_utc
            order by _ingested_at desc, _source_file desc
        ) = 1
),

final as (
    select
        interval_start_utc,
        interval_end_utc,
        consumption_mw,
        _ingested_at
    from deduplicated
)

select * from final
