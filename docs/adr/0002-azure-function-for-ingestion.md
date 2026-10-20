# 0002 — Azure Function for ingestion

- Status: accepted
- Date: 2026-10-20

## Context

Three HTTP APIs must be polled hourly and the raw responses stored in ADLS.

## Options

1. Azure Function (Python, timer trigger) — code-first, testable with pytest, cheap on the consumption plan.
2. Azure Data Factory — low-code, common in consultancies, harder to unit test and verbose in Terraform.
3. Databricks job doing the HTTP calls — fewer services, but couples ingestion to compute and costs cluster time.

## Decision

Azure Function. It keeps ingestion code testable and versioned like any Python project and shows serverless,
managed identity and Key Vault integration.

## Consequences

Python packaging and deployment of the Function must be handled in CI. ADF can be mentioned as the alternative
in interviews; a later ADR may add it if targeting ADF-heavy roles.
