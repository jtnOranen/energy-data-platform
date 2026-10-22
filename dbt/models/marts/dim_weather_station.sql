with

snapshot as (
    select * from {{ ref('weather_station_snapshot') }}
),

-- The snapshot's first version starts when the snapshot first ran, but the observations go back
-- to 2024. The first version of each station is therefore valid from the beginning of time, and
-- the current one until the end of it, so every observation finds exactly one version.
versions as (
    select
        *,
        row_number() over (partition by fmisid order by dbt_valid_from) as version_number
    from snapshot
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['fmisid', 'dbt_valid_from']) }} as weather_station_key,
        fmisid,
        station_name,
        latitude,
        longitude,
        station_role,
        case
            when version_number = 1 then cast('1900-01-01' as timestamp)
            else dbt_valid_from
        end as valid_from,
        coalesce(dbt_valid_to, cast('9999-12-31' as timestamp)) as valid_to,
        dbt_valid_to is null as is_current
    from versions
)

select * from final
