with

source as (
    select * from {{ source('bronze', 'entsoe_day_ahead_price') }}
),

typed as (
    select
        document_mrid,
        cast(revision_number as int) as revision_number,
        in_domain,
        currency_unit,
        price_measure_unit,
        curve_type,
        resolution,
        case resolution when 'PT60M' then 60 when 'PT15M' then 15 end as resolution_minutes,
        to_timestamp(period_start, "yyyy-MM-dd'T'HH:mmX") as period_start_utc,
        to_timestamp(period_end, "yyyy-MM-dd'T'HH:mmX") as period_end_utc,
        cast(position as int) as point_position,
        cast(price_amount as decimal(10, 2)) as price_eur_mwh,
        _ingested_at,
        _source_file
    from source
),

-- One fetch per delivery period, chosen as a whole: A03 omits repeated positions, so mixing points
-- from two fetches could mix their gaps. Highest revision first, then the latest fetch.
documents as (
    select
        period_start_utc,
        resolution_minutes,
        _source_file,
        max(revision_number) as revision_number,
        max(_ingested_at) as _ingested_at
    from typed
    group by period_start_utc, resolution_minutes, _source_file
),

latest_document as (
    select * from documents
    qualify
        row_number() over (
            partition by period_start_utc, resolution_minutes
            order by revision_number desc, _ingested_at desc, _source_file desc
        ) = 1
),

final as (
    select
        timestampadd(
            minute, (typed.point_position - 1) * typed.resolution_minutes, typed.period_start_utc
        ) as interval_start_utc,
        typed.resolution_minutes,
        typed.price_eur_mwh,
        typed.period_start_utc,
        typed.period_end_utc,
        typed.point_position,
        typed.resolution,
        typed.in_domain,
        typed.currency_unit,
        typed.price_measure_unit,
        typed.curve_type,
        typed.document_mrid,
        typed.revision_number,
        typed._ingested_at
    from typed
    inner join latest_document
        on
            typed.period_start_utc = latest_document.period_start_utc
            and typed.resolution_minutes = latest_document.resolution_minutes
            and typed._source_file = latest_document._source_file
)

select * from final
