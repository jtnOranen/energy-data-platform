-- Every node of a production dbt run that didn't simply pass: errors, failed and warning tests,
-- skipped nodes. Empty is the good state.
with

results as (
    select * from {{ source('ops', 'dbt_results') }}
),

final as (
    select
        invocation_id,
        run_started_at as run_started_utc,
        resource_type,
        node_name,
        status,
        failures,
        message
    from results
    where status not in ('success', 'pass')
)

select * from final
