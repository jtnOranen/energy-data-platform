{#-
    Keys to dim_date and dim_time_15min from a UTC interval start, in Finnish local time: the
    report asks about local days and hours (ADR 0005). On the autumn DST day local 03:00-03:45
    occurs twice, so two intervals share a time_key; that is right for hour-of-day profiles.
    from_utc_timestamp reads the timestamp as UTC, which holds because the warehouse session
    time zone is UTC (phase 3 spec, step 0).
-#}
{% macro local_date_key(utc_column) -%}
    cast(date_format(from_utc_timestamp({{ utc_column }}, 'Europe/Helsinki'), 'yyyyMMdd') as int)
{%- endmacro %}

{% macro local_time_key(utc_column) -%}
    cast(date_format(from_utc_timestamp({{ utc_column }}, 'Europe/Helsinki'), 'HHmm') as int)
{%- endmacro %}
