-- One row per run of this workspace's jobs (bronze_load, dbt_build, bronze_rebuild), from the
-- system tables. A view, so the pipeline-health dashboard always shows the latest runs.
with

timeline as (
    select * from {{ source('system_lakeflow', 'job_run_timeline') }}
    where workspace_id = '{{ var("workspace_id") }}'
),

jobs as (
    select * from {{ source('system_lakeflow', 'jobs') }}
    where workspace_id = '{{ var("workspace_id") }}'
),

-- The jobs table keeps every change; the newest row has the current name.
job_names as (
    select
        job_id,
        name as job_name
    from jobs
    qualify row_number() over (partition by job_id order by change_time desc) = 1
),

-- A long run is split into time slices; the final state and durations are on its last slice.
runs as (
    select
        job_id,
        run_id,
        min(period_start_time) as run_start_utc,
        max(period_end_time) as run_end_utc,
        max_by(trigger_type, period_end_time) as trigger_type,
        max_by(result_state, period_end_time) as result_state,
        max_by(termination_code, period_end_time) as termination_code,
        max(run_duration_seconds) as run_duration_seconds,
        max(setup_duration_seconds) as setup_duration_seconds
    from timeline
    group by job_id, run_id
),

final as (
    select
        runs.job_id,
        coalesce(job_names.job_name, runs.job_id) as job_name,
        runs.run_id,
        runs.run_start_utc,
        runs.run_end_utc,
        runs.trigger_type,
        runs.result_state,
        runs.termination_code,
        runs.run_duration_seconds,
        runs.setup_duration_seconds,
        runs.result_state = 'SUCCEEDED' as is_success
    from runs
    left join job_names on runs.job_id = job_names.job_id
)

select * from final
