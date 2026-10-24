-- One row per production dbt command: the daily job runs `dbt build` (models, seeds, snapshot,
-- tests) and then `dbt source freshness` (sources), and the hook stores both.
with

results as (
    select * from {{ source('ops', 'dbt_results') }}
),

final as (
    select
        invocation_id,
        min(run_started_at) as run_started_utc,
        if(count_if(resource_type = 'source') = count(*), 'source freshness', 'build') as command,
        count_if(resource_type in ('model', 'seed', 'snapshot')) as nodes_built,
        count_if(resource_type in ('model', 'seed', 'snapshot') and status = 'error')
            as nodes_errored,
        count_if(resource_type in ('test', 'unit_test')) as tests_run,
        count_if(resource_type in ('test', 'unit_test') and status in ('fail', 'error'))
            as tests_failed,
        count_if(resource_type in ('test', 'unit_test') and status = 'warn') as tests_warned,
        count_if(resource_type = 'source') as sources_checked,
        count_if(resource_type = 'source' and status in ('warn', 'error', 'runtime error'))
            as sources_stale,
        count_if(status = 'skipped') as nodes_skipped,
        sum(execution_seconds) as total_execution_seconds
    from results
    group by invocation_id
)

select * from final
