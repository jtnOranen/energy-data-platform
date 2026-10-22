# sql_warehouse

The serverless SQL warehouse dbt runs its SQL on (phase 3, ADR 0014), created with the workspace-level
`databricks` provider by the CI service principal, which then owns it.

- `<project>-<env>`, serverless (`PRO` type), 2X-Small (4 DBU/hour), exactly one cluster.
- Auto-stop after **1 minute** idle. Serverless warehouses start in seconds, so a longer idle time
  would only add cost. The API accepts 1 minute; the UI's minimum is 5.
- `no_wait`: the warehouse starts on creation, but the apply doesn't wait for it.
- The owner gets `CAN_USE` (run dbt locally, query gold). The job's run-as principal is the CI SP,
  the warehouse's owner.

Outputs: `warehouse_id` (for the bundle's dbt task) and `http_path` (for dbt profiles).

Cost: billed as serverless SQL DBUs to the workspace in `rg-energy-dev`, so the budget alerts cover it.
