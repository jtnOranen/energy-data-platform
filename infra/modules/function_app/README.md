# function_app

Ingestion function app on the Flex Consumption plan, with its monitoring and storage:

- Log Analytics workspace (daily cap as a cost guard) and workspace-based Application Insights with
  local authentication disabled.
- A host storage account (separate from the ADLS landing account) with the deployment package container.
- The function app itself, created with `azapi` (see ADR 0010), Python, system-assigned identity.

No keys or secrets anywhere: host storage, deployment storage and Application Insights use the
function's identity, and the API keys are Key Vault references. The identity gets exactly four roles:
Storage Blob Data Owner on the host storage account, Monitoring Metrics Publisher on Application
Insights, Key Vault Secrets User on the vault, and Storage Blob Data Contributor on the `landing`
container only.
