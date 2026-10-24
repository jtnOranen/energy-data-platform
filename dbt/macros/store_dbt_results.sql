{#-
    on-run-end hook: one row per node of the run (model, seed, snapshot, test, unit test) into
    <ops schema>.dbt_results, for the pipeline-health dashboard (phase 5, decision 2). Only
    production runs write, so the dashboard shows what the daily job did; a dev run can opt in
    with --vars '{store_dbt_results: true}' and then writes to dev_ops (the schema macro prefixes
    it like every other schema). `dbt source freshness` runs the hook too, so each source's
    freshness status lands here as resource_type 'source'.
-#}
{% macro store_dbt_results(results) -%}
    {%- if not execute or not results -%}
        {{ return('') }}
    {%- endif -%}
    {%- if target.name != 'prod' and not var('store_dbt_results', false) -%}
        {{ return('') }}
    {%- endif -%}

    {%- set schema = target.database ~ '.' ~ generate_schema_name('ops', none) -%}
    {%- set relation = schema ~ '.dbt_results' -%}

    {#- Terraform creates ops for production; a dev run's dev_ops is created here. -#}
    {% call statement('create_ops_schema') -%}
        create schema if not exists {{ schema }}
    {%- endcall %}

    {% call statement('create_dbt_results') -%}
        create table if not exists {{ relation }} (
            invocation_id string not null comment 'dbt invocation, one per run',
            run_started_at timestamp not null comment 'When the dbt run started, UTC',
            target_name string comment 'dbt target (prod for the daily job)',
            unique_id string not null comment 'dbt node ID, e.g. model.energy.fct_power_15min',
            resource_type string comment 'model, seed, snapshot, test or unit_test',
            node_name string comment 'Node name',
            status string comment 'success, error, skipped, pass, fail, warn',
            execution_seconds double comment 'Time the node took',
            failures bigint comment 'Failing rows for a test; null otherwise',
            rows_affected bigint comment 'Rows written, where the adapter reports it',
            message string comment 'dbt''s message for the node (first 1000 characters)'
        )
        comment 'Results of production dbt runs, one row per node (phase 5). Written by the on-run-end hook.'
    {%- endcall %}

    {%- set rows = [] -%}
    {%- for result in results -%}
        {%- set rows_affected = (result.adapter_response or {}).get('rows_affected') -%}
        {%- set message = (result.message or '') | string -%}
        {%- do rows.append(
            "('" ~ invocation_id ~ "', "
            ~ "timestamp'" ~ run_started_at.strftime('%Y-%m-%d %H:%M:%S') ~ "', "
            ~ "'" ~ target.name ~ "', "
            ~ "'" ~ result.node.unique_id ~ "', "
            ~ "'" ~ result.node.resource_type ~ "', "
            ~ "'" ~ result.node.name ~ "', "
            ~ "'" ~ result.status ~ "', "
            ~ (result.execution_time or 0) ~ ", "
            ~ (result.failures if result.failures is not none else 'null') ~ ", "
            ~ (rows_affected if rows_affected is not none and rows_affected >= 0 else 'null') ~ ", "
            ~ "'" ~ message[:1000] | replace('\\', '\\\\') | replace("'", "\\'") ~ "')"
        ) -%}
    {%- endfor -%}

    {% call statement('insert_dbt_results') -%}
        insert into {{ relation }} values
        {{ rows | join(',\n') }}
    {%- endcall %}
{%- endmacro %}
