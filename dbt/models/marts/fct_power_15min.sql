{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='interval_start_utc',
        on_schema_change='fail'
    )
}}

with

prices as (
    select * from {{ ref('int_price_15min') }}
),

power as (
    select * from {{ ref('int_power_15min') }}
),

-- A full refresh builds from the start of the history. An incremental run rebuilds the last
-- lookback_days, more than the 48-hour fetch overlap, so late and revised values replace old rows.
spine_start as (
    {% if is_incremental() %}
        select
            timestampadd(day, -{{ var('lookback_days') }}, max(interval_start_utc))
                as spine_start_utc
        from {{ this }}
    {% else %}
        select cast('{{ var("history_start_utc") }}' as timestamp) as spine_start_utc
    {% endif %}
),

spine_end as (
    select
        greatest(
            (select max(interval_start_utc) from prices),
            (select max(interval_start_utc) from power)
        ) as spine_end_utc
),

-- Every quarter-hour, whether or not a source has it: Fingrid has gaps, and a missing interval
-- should be a row with null measures, not a missing row (docs/data-sources.md).
spine as (
    select
        explode(
            sequence(
                spine_start.spine_start_utc, spine_end.spine_end_utc, interval 15 minutes
            )
        ) as interval_start_utc
    from spine_start
    cross join spine_end
),

final as (
    select
        spine.interval_start_utc,
        {{ local_date_key('spine.interval_start_utc') }} as date_key,
        {{ local_time_key('spine.interval_start_utc') }} as time_key,
        prices.price_eur_mwh,
        prices.price_resolution_minutes,
        power.wind_production_mw,
        power.consumption_mw,
        power.production_mw
    from spine
    left join prices on spine.interval_start_utc = prices.interval_start_utc
    left join power on spine.interval_start_utc = power.interval_start_utc
)

select * from final
