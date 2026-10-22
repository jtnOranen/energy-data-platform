{#-
    prod writes to the schemas Terraform created (silver, gold). Every other target prefixes them
    with its own schema (dev_silver, ci_silver, later pr_<n>_silver), so nothing but the job can
    write to production.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.name == 'prod' -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
