# 0003 — dbt for silver and gold transformations

- Status: accepted
- Date: 2026-10-20

## Context

Bronze data must be cleaned, harmonised to a 15-minute grain and modelled as a star schema, with tests and lineage.

## Options

1. dbt (dbt-databricks) on a serverless SQL warehouse — SQL models, built-in tests, unit tests, contracts, docs.
2. PySpark notebooks — flexible, but tests, lineage and docs must be built by hand.
3. Lakeflow Declarative Pipelines — good for streaming and expectations, less portable outside Databricks.

## Decision

dbt for silver and gold. PySpark only for bronze ingestion (Auto Loader).

## Consequences

Transformations are portable to Snowflake or BigQuery and testable in CI with `state:modified+`.
Declarative Pipelines are explored in project 2 (streaming) instead.
